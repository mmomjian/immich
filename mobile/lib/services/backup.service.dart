import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cancellation_token_http/http.dart' as http;
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/entities/backup_album.entity.dart';
import 'package:immich_mobile/entities/duplicated_asset.entity.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/models/backup/backup_candidate.model.dart';
import 'package:immich_mobile/models/backup/current_upload_asset.model.dart';
import 'package:immich_mobile/models/backup/error_upload_asset.model.dart';
import 'package:immich_mobile/models/backup/success_upload_asset.model.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/db.provider.dart';
import 'package:immich_mobile/services/album.service.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart' as pm;
import 'package:photo_manager/photo_manager.dart';

final backupServiceProvider = Provider(
  (ref) => BackupService(
    ref.watch(apiServiceProvider),
    ref.watch(dbProvider),
    ref.watch(appSettingsServiceProvider),
    ref.watch(albumServiceProvider),
  ),
);

class BackupService {
  final httpClient = http.Client();
  final ApiService _apiService;
  final Isar _db;
  final Logger _log = Logger("BackupService");
  final AppSettingsService _appSetting;
  final AlbumService _albumService;

  BackupService(
    this._apiService,
    this._db,
    this._appSetting,
    this._albumService,
  );

  Future<List<String>?> getDeviceBackupAsset() async {
    final String deviceId = Store.get(StoreKey.deviceId);

    try {
      return await _apiService.assetsApi.getAllUserAssetsByDeviceId(deviceId);
    } catch (e) {
      debugPrint('Error [getDeviceBackupAsset] ${e.toString()}');
      return null;
    }
  }

  Future<void> _saveDuplicatedAssetIds(List<String> deviceAssetIds) {
    final duplicates = deviceAssetIds.map((id) => DuplicatedAsset(id)).toList();
    return _db.writeTxn(() => _db.duplicatedAssets.putAll(duplicates));
  }

  /// Get duplicated asset id from database
  Future<Set<String>> getDuplicatedAssetIds() async {
    final duplicates = await _db.duplicatedAssets.where().findAll();
    return duplicates.map((e) => e.id).toSet();
  }

  QueryBuilder<BackupAlbum, BackupAlbum, QAfterFilterCondition>
      selectedAlbumsQuery() =>
          _db.backupAlbums.filter().selectionEqualTo(BackupSelection.select);
  QueryBuilder<BackupAlbum, BackupAlbum, QAfterFilterCondition>
      excludedAlbumsQuery() =>
          _db.backupAlbums.filter().selectionEqualTo(BackupSelection.exclude);

  /// Returns all assets newer than the last successful backup per album
  /// if `useTimeFilter` is set to true, all assets will be returned
  Future<Set<BackupCandidate>> buildUploadCandidates(
    List<BackupAlbum> selectedBackupAlbums,
    List<BackupAlbum> excludedBackupAlbums, {
    bool useTimeFilter = true,
  }) async {
    final filter = FilterOptionGroup(
      containsPathModified: true,
      orders: [const OrderOption(type: OrderOptionType.updateDate)],
      // title is needed to create Assets
      imageOption: const FilterOption(needTitle: true),
      videoOption: const FilterOption(needTitle: true),
    );
    final now = DateTime.now();

    final List<AssetPathEntity?> selectedAlbums =
        await _loadAlbumsWithTimeFilter(
      selectedBackupAlbums,
      filter,
      now,
      useTimeFilter: useTimeFilter,
    );

    if (selectedAlbums.every((e) => e == null)) {
      return {};
    }

    final List<AssetPathEntity?> excludedAlbums =
        await _loadAlbumsWithTimeFilter(
      excludedBackupAlbums,
      filter,
      now,
      useTimeFilter: useTimeFilter,
    );

    final Set<BackupCandidate> toAdd = await _fetchAssetsAndUpdateLastBackup(
      selectedAlbums,
      selectedBackupAlbums,
      now,
      useTimeFilter: useTimeFilter,
    );

    final Set<BackupCandidate> toRemove = await _fetchAssetsAndUpdateLastBackup(
      excludedAlbums,
      excludedBackupAlbums,
      now,
      useTimeFilter: useTimeFilter,
    );

    return toAdd.difference(toRemove);
  }

  Future<List<AssetPathEntity?>> _loadAlbumsWithTimeFilter(
    List<BackupAlbum> albums,
    FilterOptionGroup filter,
    DateTime now, {
    bool useTimeFilter = true,
  }) async {
    List<AssetPathEntity?> result = [];
    for (BackupAlbum backupAlbum in albums) {
      try {
        final optionGroup = useTimeFilter
            ? filter.copyWith(
                updateTimeCond: DateTimeCond(
                  // subtract 2 seconds to prevent missing assets due to rounding issues
                  min: backupAlbum.lastBackup
                      .subtract(const Duration(seconds: 2)),
                  max: now,
                ),
              )
            : filter;

        final AssetPathEntity album =
            await AssetPathEntity.obtainPathFromProperties(
          id: backupAlbum.id,
          optionGroup: optionGroup,
          maxDateTimeToNow: false,
        );

        result.add(album);
      } on StateError {
        // either there are no assets matching the filter criteria OR the album no longer exists
      }
    }

    return result;
  }

  Future<Set<BackupCandidate>> _fetchAssetsAndUpdateLastBackup(
    List<AssetPathEntity?> localAlbums,
    List<BackupAlbum> backupAlbums,
    DateTime now, {
    bool useTimeFilter = true,
  }) async {
    Set<BackupCandidate> candidate = {};

    for (int i = 0; i < localAlbums.length; i++) {
      final localAlbum = localAlbums[i];
      if (localAlbum == null) {
        continue;
      }

      if (useTimeFilter &&
          localAlbum.lastModified?.isBefore(backupAlbums[i].lastBackup) ==
              true) {
        continue;
      }

      final assets = await localAlbum.getAssetListRange(
        start: 0,
        end: await localAlbum.assetCountAsync,
      );

      // Add album's name to the asset info
      for (final asset in assets) {
        List<String> albumNames = [localAlbum.name];

        final existingAsset = candidate.firstWhereOrNull(
          (a) => a.asset.id == asset.id,
        );

        if (existingAsset != null) {
          albumNames.addAll(existingAsset.albumNames);
          candidate.remove(existingAsset);
        }

        candidate.add(
          BackupCandidate(
            asset: asset,
            albumNames: albumNames,
          ),
        );
      }

      backupAlbums[i].lastBackup = now;
    }

    return candidate;
  }

  /// Returns a new list of assets not yet uploaded
  Future<Set<BackupCandidate>> removeAlreadyUploadedAssets(
    Set<BackupCandidate> candidates,
  ) async {
    if (candidates.isEmpty) {
      return candidates;
    }

    final Set<String> duplicatedAssetIds = await getDuplicatedAssetIds();
    candidates.removeWhere(
      (candidate) => duplicatedAssetIds.contains(candidate.asset.id),
    );

    if (candidates.isEmpty) {
      return candidates;
    }

    final Set<String> existing = {};
    try {
      final String deviceId = Store.get(StoreKey.deviceId);
      final CheckExistingAssetsResponseDto? duplicates =
          await _apiService.assetsApi.checkExistingAssets(
        CheckExistingAssetsDto(
          deviceAssetIds: candidates.map((c) => c.asset.id).toList(),
          deviceId: deviceId,
        ),
      );
      if (duplicates != null) {
        existing.addAll(duplicates.existingIds);
      }
    } on ApiException {
      // workaround for older server versions or when checking for too many assets at once
      final List<String>? allAssetsInDatabase = await getDeviceBackupAsset();
      if (allAssetsInDatabase != null) {
        existing.addAll(allAssetsInDatabase);
      }
    }

    if (existing.isNotEmpty) {
      candidates.removeWhere((c) => existing.contains(c.asset.id));
    }

    return candidates;
  }

  Future<bool> _checkPermissions() async {
    if (Platform.isAndroid &&
        !(await pm.Permission.accessMediaLocation.status).isGranted) {
      // double check that permission is granted here, to guard against
      // uploading corrupt assets without EXIF information
      _log.warning("Media location permission is not granted. "
          "Cannot access original assets for backup.");

      return false;
    }

    // DON'T KNOW WHY BUT THIS HELPS BACKGROUND BACKUP TO WORK ON IOS
    if (Platform.isIOS) {
      await PhotoManager.requestPermissionExtend();
    }

    return true;
  }

  /// Upload images before video assets for background tasks
  /// these are further sorted by using their creation date
  List<BackupCandidate> _sortPhotosFirst(List<BackupCandidate> candidates) {
    return candidates.sorted(
      (a, b) {
        final cmp = a.asset.typeInt - b.asset.typeInt;
        if (cmp != 0) return cmp;
        return a.asset.createDateTime.compareTo(b.asset.createDateTime);
      },
    );
  }

  Future<bool> backupAsset(
    Iterable<BackupCandidate> assets,
    http.CancellationToken cancelToken, {
    bool isBackground = false,
    PMProgressHandler? pmProgressHandler,
    required void Function(SuccessUploadAsset result) onSuccess,
    required void Function(int bytes, int totalBytes) onProgress,
    required void Function(CurrentUploadAsset asset) onCurrentAsset,
    required void Function(ErrorUploadAsset error) onError,
  }) async {
    final bool isIgnoreIcloudAssets =
        _appSetting.getSetting(AppSettingsEnum.ignoreIcloudAssets);
    final shouldSyncAlbums = _appSetting.getSetting(AppSettingsEnum.syncAlbums);
    final String deviceId = Store.get(StoreKey.deviceId);
    final String savedEndpoint = Store.get(StoreKey.serverEndpoint);
    final List<String> duplicatedAssetIds = [];
    bool anyErrors = false;

    final hasPermission = await _checkPermissions();
    if (!hasPermission) {
      return false;
    }

    List<BackupCandidate> candidates = assets.toList();
    if (isBackground) {
      candidates = _sortPhotosFirst(candidates);
    }

    for (final candidate in candidates) {
      final AssetEntity entity = candidate.asset;
      File? file;
      File? livePhotoFile;

      try {
        final isAvailableLocally =
            await entity.isLocallyAvailable(isOrigin: true);

        // Handle getting files from iCloud
        if (!isAvailableLocally && Platform.isIOS) {
          // Skip iCloud assets if the user has disabled this feature
          if (isIgnoreIcloudAssets) {
            continue;
          }

          onCurrentAsset(
            CurrentUploadAsset(
              id: entity.id,
              fileCreatedAt: entity.createDateTime.year == 1970
                  ? entity.modifiedDateTime
                  : entity.createDateTime,
              fileName: await entity.titleAsync,
              fileType: _getAssetType(entity.type),
              iCloudAsset: true,
            ),
          );

          file = await entity.loadFile(progressHandler: pmProgressHandler);
          if (entity.isLivePhoto) {
            livePhotoFile = await entity.loadFile(
              withSubtype: true,
              progressHandler: pmProgressHandler,
            );
          }
        } else {
          if (entity.type == AssetType.video) {
            file = await entity.originFile;
          } else {
            file = await entity.originFile.timeout(const Duration(seconds: 5));
            if (entity.isLivePhoto) {
              livePhotoFile = await entity.originFileWithSubtype
                  .timeout(const Duration(seconds: 5));
            }
          }
        }

        if (file != null) {
          String originalFileName = await entity.titleAsync;

          if (entity.isLivePhoto) {
            if (livePhotoFile == null) {
              _log.warning(
                "Failed to obtain motion part of the livePhoto - $originalFileName",
              );
            }
          }

          final fileStream = file.openRead();
          final assetRawUploadData = http.MultipartFile(
            "assetData",
            fileStream,
            file.lengthSync(),
            filename: originalFileName,
          );

          final baseRequest = MultipartRequest(
            'POST',
            Uri.parse('$savedEndpoint/assets'),
            onProgress: ((bytes, totalBytes) => onProgress(bytes, totalBytes)),
          );

          baseRequest.headers.addAll(ApiService.getRequestHeaders());
          baseRequest.headers["Transfer-Encoding"] = "chunked";
          baseRequest.fields['deviceAssetId'] = entity.id;
          baseRequest.fields['deviceId'] = deviceId;
          baseRequest.fields['fileCreatedAt'] =
              entity.createDateTime.toUtc().toIso8601String();
          baseRequest.fields['fileModifiedAt'] =
              entity.modifiedDateTime.toUtc().toIso8601String();
          baseRequest.fields['isFavorite'] = entity.isFavorite.toString();
          baseRequest.fields['duration'] = entity.videoDuration.toString();
          baseRequest.files.add(assetRawUploadData);

          onCurrentAsset(
            CurrentUploadAsset(
              id: entity.id,
              fileCreatedAt: entity.createDateTime.year == 1970
                  ? entity.modifiedDateTime
                  : entity.createDateTime,
              fileName: originalFileName,
              fileType: _getAssetType(entity.type),
              fileSize: file.lengthSync(),
              iCloudAsset: false,
            ),
          );

          String? livePhotoVideoId;
          if (entity.isLivePhoto && livePhotoFile != null) {
            livePhotoVideoId = await uploadLivePhotoVideo(
              originalFileName,
              livePhotoFile,
              baseRequest,
              cancelToken,
            );
          }

          if (livePhotoVideoId != null) {
            baseRequest.fields['livePhotoVideoId'] = livePhotoVideoId;
          }

          final response = await httpClient.send(
            baseRequest,
            cancellationToken: cancelToken,
          );

          final responseBody =
              jsonDecode(await response.stream.bytesToString());

          if (![200, 201].contains(response.statusCode)) {
            final error = responseBody;
            final errorMessage = error['message'] ?? error['error'];

            debugPrint(
              "Error(${error['statusCode']}) uploading ${entity.id} | $originalFileName | Created on ${entity.createDateTime} | ${error['error']}",
            );

            onError(
              ErrorUploadAsset(
                asset: entity,
                id: entity.id,
                fileCreatedAt: entity.createDateTime,
                fileName: originalFileName,
                fileType: _getAssetType(entity.type),
                errorMessage: errorMessage,
              ),
            );

            if (errorMessage == "Quota has been exceeded!") {
              anyErrors = true;
              break;
            }

            continue;
          }

          bool isDuplicate = false;
          if (response.statusCode == 200) {
            isDuplicate = true;
            duplicatedAssetIds.add(entity.id);
          }

          onSuccess(
            SuccessUploadAsset(
              candidate: candidate,
              remoteAssetId: responseBody['id'] as String,
              isDuplicate: isDuplicate,
            ),
          );

          if (shouldSyncAlbums) {
            await _albumService.syncUploadAlbums(
              candidate.albumNames,
              [responseBody['id'] as String],
            );
          }
        }
      } on http.CancelledException {
        debugPrint("Backup was cancelled by the user");
        anyErrors = true;
        break;
      } catch (error, stackTrace) {
        debugPrint("Error backup asset: ${error.toString()}: $stackTrace");
        anyErrors = true;
        continue;
      } finally {
        if (Platform.isIOS) {
          try {
            await file?.delete();
            await livePhotoFile?.delete();
          } catch (e) {
            debugPrint("ERROR deleting file: ${e.toString()}");
          }
        }
      }
    }

    if (duplicatedAssetIds.isNotEmpty) {
      await _saveDuplicatedAssetIds(duplicatedAssetIds);
    }

    return !anyErrors;
  }

  Future<String?> uploadLivePhotoVideo(
    String originalFileName,
    File? livePhotoVideoFile,
    MultipartRequest baseRequest,
    http.CancellationToken cancelToken,
  ) async {
    if (livePhotoVideoFile == null) {
      return null;
    }
    final livePhotoTitle = p.setExtension(
      originalFileName,
      p.extension(livePhotoVideoFile.path),
    );
    final fileStream = livePhotoVideoFile.openRead();
    final livePhotoRawUploadData = http.MultipartFile(
      "assetData",
      fileStream,
      livePhotoVideoFile.lengthSync(),
      filename: livePhotoTitle,
    );
    final livePhotoReq = MultipartRequest(
      baseRequest.method,
      baseRequest.url,
      onProgress: baseRequest.onProgress,
    )
      ..headers.addAll(baseRequest.headers)
      ..fields.addAll(baseRequest.fields);

    livePhotoReq.files.add(livePhotoRawUploadData);

    var response = await httpClient.send(
      livePhotoReq,
      cancellationToken: cancelToken,
    );

    var responseBody = jsonDecode(await response.stream.bytesToString());

    if (![200, 201].contains(response.statusCode)) {
      var error = responseBody;

      debugPrint(
        "Error(${error['statusCode']}) uploading livePhoto for assetId | $livePhotoTitle | ${error['error']}",
      );
    }

    return responseBody.containsKey('id') ? responseBody['id'] : null;
  }

  String _getAssetType(AssetType assetType) {
    switch (assetType) {
      case AssetType.audio:
        return "AUDIO";
      case AssetType.image:
        return "IMAGE";
      case AssetType.video:
        return "VIDEO";
      case AssetType.other:
        return "OTHER";
    }
  }
}

class MultipartRequest extends http.MultipartRequest {
  /// Creates a new [MultipartRequest].
  MultipartRequest(
    super.method,
    super.url, {
    required this.onProgress,
  });

  final void Function(int bytes, int totalBytes) onProgress;

  /// Freezes all mutable fields and returns a
  /// single-subscription [http.ByteStream]
  /// that will emit the request body.
  @override
  http.ByteStream finalize() {
    final byteStream = super.finalize();

    final total = contentLength;
    var bytes = 0;

    final t = StreamTransformer.fromHandlers(
      handleData: (List<int> data, EventSink<List<int>> sink) {
        bytes += data.length;
        onProgress.call(bytes, total);
        sink.add(data);
      },
    );
    final stream = byteStream.transform(t);
    return http.ByteStream(stream);
  }
}
