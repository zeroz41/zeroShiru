<script context='module'>
  import { since, isValidNumber, createListener } from '@/modules/util.js'
  import TorrentButton from '@/components/TorrentButton.svelte'
  import SmartImage from '@/components/visual/SmartImage.svelte'
  import { Play, MailCheck, MailOpen } from 'lucide-svelte'

  const { reactive, init } = createListener(['torrent-button', 'read-button', 'continue-button', 'n-safe-area'])
  init(true)
</script>
<script>
  import { localNotifications } from '@/modules/notification/manager.js'
  import { click, hoverExit, blurExit } from '@/modules/lib/click.js'
  import { getFlags } from '@/modules/notification/util.js'
  import { getHash } from '@/modules/anime/animehash.js'
  import { SUPPORTS } from '@/modules/support.js'

  /** @type {number} */
  export let index = -1
  /** @type {import('@/modules/providers/anilist/al.d.ts').Media} Resolved media for this notification */
  export let media
  /** @type {object} The notification record from the store */
  export let notification
  /** @type {Function} */
  export let onClick = () => {}

  /** @type {boolean} */
  let prompt = false

  $: ({ delayed, announcement, repeating, notWatching, behind, completed } = getFlags(notification, media))
  $: resolvedHash = getHash(notification.id, { episode: notification.episode, client: true }, false, true)
  $: isUnread = !($localNotifications.find((n) => n.uid === notification.uid)?.read)

  /** Handles primary click on notification card, plays content or opens continue prompt */
  function handleCardClick() {
    if (!behind || prompt) {
      prompt = false
      onClick(notification)
    } else {
      prompt = true
    }
  }

  /** Marks notification as read and opens detail view (context menu action) */
  function handleContextMenu() {
    onClick(notification, true)
  }

  /** Toggles read/unread state for notification */
  function handleToggleRead() {
    prompt = false
    if (isUnread || !completed) {
      const value = isUnread
      localNotifications.update((n) => {
        const found = n.find((x) => x.uid === notification.uid)
        if (found) found.read = value
        return [...n]
      })
    }
  }

  /** Calls playback continuation even if user is behind */
  function handlePromptPlay() {
    prompt = false
    onClick(notification)
  }

  /** Closes continue anyway prompt if active */
  function dismissPrompt() {
    if (prompt) setTimeout(() => prompt = false).unref?.()
  }
</script>

<div
    class='notification-item shadow-lg position-relative d-flex align-items-center mx-20 my-5 p-5 scale pointer'
    style:--status-color={notWatching && !delayed ? 'var(--gray-color-very-dim)' : completed && !delayed ? 'var(--completed-color)' : announcement ? 'var(--duodenary-color)' : (behind && !notWatching) || delayed ? 'var(--dropped-color)' : !behind && !notWatching && !repeating ? 'var(--current-color)' : !behind && !notWatching && repeating ? 'var(--repeating-color)' : ''}
    role='button'
    tabindex='0'
    class:read={!isUnread}
    class:behind={(behind && !notWatching) || delayed}
    class:current={!behind && !notWatching && !repeating}
    class:repeating={!behind && !notWatching && repeating}
    class:not-watching={notWatching}
    class:completed={completed}
    class:announcement={announcement}
    class:not-reactive={!$reactive}
    class:mt-15={index === 0}
    use:blurExit={dismissPrompt}
    use:hoverExit={dismissPrompt}
    use:click={handleCardClick}
    on:contextmenu|preventDefault={handleContextMenu}>
  {#if notification.heroImg}
    <div class='position-absolute top-0 left-0 w-full h-full'>
      <SmartImage class={`img-cover w-full h-full`} images={[notification.heroImg, media?.bannerImage, (media?.trailer?.id && `https://i.ytimg.com/vi/${media?.trailer?.id}/hqdefault.jpg`)]} style='border-radius: .75rem;'/>
      <div class='position-absolute rounded-5 opacity-transition-hack' style='background: var(--notification-card-gradient)' />
    </div>
  {/if}
  <div class='rounded-5 d-flex justify-content-center align-items-center overflow-hidden mr-10 z-10 icon-container'>
    <SmartImage class={`rounded-5 w-auto`} images={[notification.iconXL, notification.icon, media?.coverImage?.extraLarge, media?.coverImage?.medium, (!media ? './404_cover.jpg' : './no_image_cover.jpg')]} color='var(--status-color)' style='height: 100%; object-fit: cover; object-position: center;'/>
  </div>
  <div class='notification-content z-10 w-full'>
    <div class='d-flex'>
      <p class='notification-title overflow-hidden font-weight-bold my-0 mt-5 mr-10 font-scale-18 {SUPPORTS.isAndroid ? `line-clamp-1` : `line-clamp-2`}'>
        {notification.title}
      </p>
      <div class='ml-auto d-flex '>
        <button type='button' tabindex='-1' class='position-absolute n-safe-area top-0 right-0 h-50 bg-transparent border-0 shadow-none not-reactive z-1 {notification.hash || resolvedHash ? `w-90` : `w-50`}' use:click={() => {}}/> <!-- HACK: Prevents accidental tapping -->
        {#if notification.hash || resolvedHash}
          <TorrentButton
              class='torrent-button btn btn-square mr-5 z-1'
              hash={[...(notification.hash && notification.hash !== resolvedHash ? [notification.hash] : []), ...(resolvedHash ? [resolvedHash] : [])]}
              torrentID={notification.magnet}
              search={{ media: { id: notification.id }, episode: notification.episode }}/>
        {/if}
        <button type='button' class='read-button btn btn-square d-flex align-items-center justify-content-center z-1' class:not-allowed={completed} class:not-reactive={completed} use:click={handleToggleRead}>
          {#if !isUnread}
            <MailOpen size='1.7rem' strokeWidth='3' />
          {:else}
            <MailCheck size='1.7rem' strokeWidth='3' />
          {/if}
        </button>
      </div>
    </div>
    <p class='font-size-12 my-0 mr-40' class:mr-80={notification.hash || resolvedHash}>{notification.message}</p>
    <div class='d-flex justify-content-between align-items-center mt-5'>
      <p class='font-size-10 text-muted my-0'>{since(new Date(notification.timestamp * 1_000))}</p>
      <div class='badge-container'>
        {#if announcement}
          <span class='badge wash mr-5' style='--badge-color: var(--duodenary-color)'>Announcement</span>
        {:else if notification.format === 'MOVIE'}
          <span class='badge wash mr-5' style='--badge-color: var(--undenary-color)'>Movie</span>
        {:else if !isValidNumber(notification.season)}
          {#if delayed}<span class='badge wash mr-5' style='--badge-color: var(--denary-color)'>Delayed</span>{/if}
          <span class='badge wash mr-5' style='--badge-color: var(--undenary-color)'>
            {notification.episode != null && (Array.isArray(notification.episode) || isValidNumber(notification.episode))
              ? `Episode ${Array.isArray(notification.episode) ? `${Number(notification.episode[0])} ~ ${Number(notification.episode[1])}` : Number(notification.episode)}`
              : 'Batch'}
          </span>
        {:else if isValidNumber(notification.season)}
          <span class='badge wash mr-5' style='--badge-color: var(--undenary-color)'>Season {notification.season}</span>
        {/if}
        {#if notification.dub}
          <span class='badge wash' style='--badge-color: var(--senary-color)'>Dub</span>
        {:else}
          <span class='badge wash' style='--badge-color: var(--septenary-color)'>Sub</span>
        {/if}
      </div>
    </div>
    <div class='position-absolute bd-highlight rounded-5 opacity-transition-hack' style='left: -.5rem' />
  </div>
  <div class='prompt position-absolute z-40 d-none flex-column align-items-center' class:d-flex={prompt}>
    <p class='mx-20 font-scale-20 text-white text-center mt-auto mb-0'>
      {#if !media?.mediaListEntry?.progress}
        You Haven't Watched Any Episodes Yet!
      {:else}
        Your Current Progress Is At <b>Episode {media?.mediaListEntry?.progress}</b>
      {/if}
    </p>
    <button type='button' class='continue-button btn btn-lg btn-secondary w-230 h-33 text-dark font-scale-16 font-weight-bold shadow-none border-0 d-flex align-items-center mt-10 mb-auto' use:click={handlePromptPlay}>
      <Play class='mr-10' fill='currentColor' size='1.4rem' />
      Continue Anyway?
    </button>
  </div>
</div>

<style>
  .h-33 {
    height: 3.3rem !important;
  }
  .mr-80 {
    margin-right: 8rem !important;
  }
  .scale {
    /* the `scale` property, not a transform, so nothing that positions itself with a
       transform is claimed — and no standing will-change layer. See FullCard */
    transition: scale var(--motion) var(--ease-settle);
  }
  @media (hover: hover) and (pointer: fine) {
    .scale:hover {
      scale: 1.02;
    }
  }
  .wash {
    border: none;
    background: color-mix(in srgb, var(--badge-color) 16%, transparent);
    box-shadow: inset 0 0 0 .1rem color-mix(in srgb, var(--badge-color) 35%, transparent);
    color: color-mix(in srgb, var(--badge-color) 65%, var(--highlight-color));
  }
  .font-size-10 {
    font-size: 1rem;
  }

  @keyframes slide-in {
    from {
      opacity: 0;
      transform: translateY(1rem);
    }
    to { transform: translateY(0) }
  }
  .notification-item {
    background-color: var(--dark-color-light);
    animation: slide-in .5s ease forwards;
    border-radius: .75rem;
  }
  .notification-item {
    border-left: .4rem solid var(--status-color);
  }
  .notification-item.read {
    opacity: .5;
  }

  .notification-title {
    display: -webkit-box;
    -webkit-box-orient: vertical;
    text-overflow: ellipsis;
    word-wrap: break-word;
  }
  .line-clamp-1 { line-height: 1.8; -webkit-line-clamp: 1; }
  .line-clamp-2 { line-height: 1.2; -webkit-line-clamp: 2; }

  .icon-container {
    width: 6rem;
    height: 8rem;
  }

  .prompt {
    inset: 0;
    border-radius: .55rem;
    background-color: hsla(var(--black-color-hsl), .8) !important;
  }
</style>