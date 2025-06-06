<script lang="ts">
  import { page } from '$app/state';
  import { focusTrap } from '$lib/actions/focus-trap';
  import CircleIconButton from '$lib/components/elements/buttons/circle-icon-button.svelte';
  import Icon from '$lib/components/elements/icon.svelte';
  import { AppRoute } from '$lib/constants';
  import { modalManager } from '$lib/managers/modal-manager.svelte';
  import AvatarEditModal from '$lib/modals/AvatarEditModal.svelte';
  import { user } from '$lib/stores/user.store';
  import { Button } from '@immich/ui';
  import { mdiCog, mdiLogout, mdiPencil, mdiWrench } from '@mdi/js';
  import { t } from 'svelte-i18n';
  import { fade } from 'svelte/transition';
  import UserAvatar from '../user-avatar.svelte';

  interface Props {
    onLogout: () => void;
    onClose?: () => void;
  }

  let { onLogout, onClose = () => {} }: Props = $props();
</script>

<div
  in:fade={{ duration: 100 }}
  out:fade={{ duration: 100 }}
  id="account-info-panel"
  class="absolute z-1 end-[25px] top-[75px] w-[min(360px,100vw-50px)] rounded-3xl bg-gray-200 shadow-lg dark:border dark:border-immich-dark-gray dark:bg-immich-dark-gray"
  use:focusTrap
>
  <div
    class="mx-4 mt-4 flex flex-col items-center justify-center gap-4 rounded-3xl bg-white p-4 dark:bg-immich-dark-primary/10"
  >
    <div class="relative">
      <UserAvatar user={$user} size="xl" />
      <div class="absolute bottom-0 end-0 rounded-full w-6 h-6">
        <CircleIconButton
          color="primary"
          icon={mdiPencil}
          title={$t('edit_avatar')}
          class="border"
          size="12"
          padding="2"
          onclick={() => modalManager.show(AvatarEditModal, {})}
        />
      </div>
    </div>
    <div>
      <p class="text-center text-lg font-medium text-immich-primary dark:text-immich-dark-primary">
        {$user.name}
      </p>
      <p class="text-sm text-gray-500 dark:text-immich-dark-fg">{$user.email}</p>
    </div>

    <div class="flex flex-col gap-1">
      <Button
        href={AppRoute.USER_SETTINGS}
        onclick={onClose}
        size="small"
        color="secondary"
        variant="ghost"
        shape="round"
        class="border dark:border-immich-dark-gray dark:bg-gray-500 dark:hover:bg-immich-dark-primary/50 hover:bg-immich-primary/10 dark:text-white"
      >
        <div class="flex place-content-center place-items-center text-center gap-2 px-2">
          <Icon path={mdiCog} size="18" ariaHidden />
          {$t('account_settings')}
        </div>
      </Button>
      {#if $user.isAdmin}
        <Button
          href={AppRoute.ADMIN_USERS}
          onclick={onClose}
          shape="round"
          variant="ghost"
          size="small"
          color="secondary"
          aria-current={page.url.pathname.includes('/admin') ? 'page' : undefined}
          class="border dark:border-immich-dark-gray dark:bg-gray-500 dark:hover:bg-immich-dark-primary/50 hover:bg-immich-primary/10 dark:text-white"
        >
          <div class="flex place-content-center place-items-center text-center gap-2 px-2">
            <Icon path={mdiWrench} size="18" ariaHidden />
            {$t('administration')}
          </div>
        </Button>
      {/if}
    </div>
  </div>

  <div class="mb-4 flex flex-col">
    <button
      type="button"
      class="flex w-full place-content-center place-items-center gap-2 py-3 font-medium text-gray-500 hover:bg-immich-primary/10 dark:text-gray-300"
      onclick={onLogout}
    >
      <Icon path={mdiLogout} size={24} />
      {$t('sign_out')}</button
    >
  </div>
</div>
