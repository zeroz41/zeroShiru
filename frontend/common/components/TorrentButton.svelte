<script context='module'>
    import { Download, CloudUpload, CloudDownload, FolderX, FolderCheck, TvMinimalPlay } from 'lucide-svelte'
    import { settings } from '@/modules/settings.js'
    import { add, stage, loadedTorrent, stagingTorrents, seedingTorrents, completedTorrents } from '@/modules/torrent.js'
    import { getHash } from '@/modules/anime/animehash.js'
    import { handlePlay, handleAnime } from '@/modules/anime/anime.js'
    import { click } from '@/modules/lib/click.js'

    export function playActive(hash, search, magnet, prompt = true) {
        const autoFile = settings.value.rssAutofile
        const resolvedHash = getHash(search?.media?.id, { episode: search?.episode, client: true, batchGuess: true }, false, true)
        const activeHash = autoFile && getActiveHash([...(hash && hash !== resolvedHash ? [hash] : []), ...(resolvedHash ? [resolvedHash] : [])], false)
        if (activeHash && loadedTorrent.value?.infoHash !== activeHash && loadedTorrent.value?.fileHash !== activeHash) { // We have a cached and active hash with the requested media and episode, its predicted we should use this.
            add(activeHash, search, activeHash)
        } else if ((autoFile || !prompt) && magnet && (!hash || (hash !== loadedTorrent.value?.infoHash && hash !== loadedTorrent.value?.fileHash))) { // Nothing found, request download from magnet.
            add(magnet, null, null, null)
        } else if (prompt) { // Nothing found and no magnet, prompt user to locate torrent.
            handlePlay(search?.media?.id, search?.episode, true)
        } else { // Nothing found, no magnet, and cannot prompt, show the anime details.
            handleAnime({ id: search?.media?.id })
        }
    }

    function getActiveHash(hash, ignoreCached = true) {
        for (const _hash of hash) {
            if (loadedTorrent.value?.infoHash === _hash) return _hash
        }
        for (const _hash of hash) {
            if (seedingTorrents.value.some(torrent => torrent.infoHash === _hash)) return _hash
        }
        for (const _hash of hash) {
            if (completedTorrents.value.some(torrent => torrent.infoHash === _hash)) return _hash
        }
        for (const _hash of hash) {
            if (stagingTorrents.value.some(torrent => torrent.infoHash === _hash)) return _hash
        }
        return ignoreCached ? hash[0] : null
    }
</script>
<script>
    export let hash
    export let search
    export let torrentID = null
    export let size = '1.7rem'
    export let strokeWidth = '3'
    $: disabled = ($seedingTorrents?.length + $stagingTorrents?.length + 1) >= settings.value.seedingLimit && !settings.value.torrentPersist
    $: activeHash = $loadedTorrent && $stagingTorrents && $seedingTorrents && $completedTorrents && (Array.isArray(hash) ? getActiveHash(hash) : hash)
    $: downloaded = ($completedTorrents.some(torrent => torrent.infoHash === activeHash) && !$completedTorrents.find(torrent => torrent.infoHash === activeHash).incomplete) || $seedingTorrents.some(torrent => torrent.infoHash === activeHash) || $stagingTorrents.some(torrent => torrent.infoHash === activeHash) || $loadedTorrent.infoHash === activeHash
</script>
<button type='button' class='torrent-button d-flex align-items-center justify-content-center {$$restProps.class}' class:not-allowed={downloaded || disabled} class:not-reactive={downloaded || disabled} disabled={disabled && !downloaded} title='' data-toggle='tooltip' data-placement='left' data-title={$completedTorrents.some(torrent => torrent.infoHash === activeHash) ? ($completedTorrents.find(torrent => torrent.infoHash === activeHash).incomplete ? 'Download Incomplete' : 'Download Completed') : $seedingTorrents.some(torrent => torrent.infoHash === activeHash) ? 'Seeding...' : $stagingTorrents.some(torrent => torrent.infoHash === activeHash) ? 'Downloading...' : $loadedTorrent.infoHash === activeHash ? 'Now Playing' : (!disabled ? 'Queue for Download' : 'Enable Persist Files or Increase Seeding Limit')} use:click={() => { if (!disabled && !downloaded && torrentID) stage(torrentID, search, activeHash) }}>
    <svelte:component this={$completedTorrents.some(torrent => torrent.infoHash === activeHash) ? ($completedTorrents.find(torrent => torrent.infoHash === activeHash).incomplete ? FolderX : FolderCheck) : $seedingTorrents.some(torrent => torrent.infoHash === activeHash) ? CloudUpload : $stagingTorrents.some(torrent => torrent.infoHash === activeHash) ? CloudDownload : $loadedTorrent.infoHash === activeHash ? TvMinimalPlay : Download} {size} {strokeWidth} style={downloaded ? (`color: ${$completedTorrents.some(torrent => torrent.infoHash === activeHash) ? 'var(--quaternary-color)' : $seedingTorrents.some(torrent => torrent.infoHash === activeHash) ? 'var(--tertiary-color)' : $stagingTorrents.some(torrent => torrent.infoHash === activeHash) ? 'var(--warning-color)' : 'var(--quaternary-color)'}`) : (($completedTorrents.find(torrent => torrent.infoHash === activeHash)?.incomplete ? 'color: var(--error-color)' : ''))} />
</button>