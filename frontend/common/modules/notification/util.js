import { isValidNumber, matchPhrase, matchKeys, generateRandomHexCode } from '@/modules/util.js'
import Helper from '@/modules/providers/helper.js'
import { settings } from '@/modules/settings.js'
import { cache } from '@/modules/cache.js'

const SYSTEM_KEYS = ['id', 'title', 'message', 'timestamp', 'icon', 'iconXL', 'heroImg', 'button', 'activation']

/**
 * Sorts notifications by unread before read, then by timestamp descending,
 * with episode ordering as a tiebreaker for the same series
 *
 * @param {Object[]} array
 * @returns {Object[]}
 */
export function sort(array) {
  return array.sort((a, b) => {
    const timeDiff = b.timestamp - a.timestamp
    if (timeDiff !== 0) return timeDiff
    if (a.id === b.id
      && isValidNumber(a.episode) && isValidNumber(b.episode)
      && isValidNumber(a.season) && isValidNumber(b.season)) {
      return b.episode - a.episode
    }
    return 0
  }).sort((a, b) => {
    if (!a.read && b.read) return -1
    if (a.read && !b.read) return 1
    return 0
  })
}

/**
 * Filters a notifications array by a search string, matching on title or any of the media title variants / synonyms.
 *
 * @param {Object[]} notifications
 * @param {string} searchText
 * @returns {Object[]}
 */
export function filter(notifications, searchText) {
  if (!searchText?.length) return notifications
  return (notifications.filter(({ id, title }) =>
      matchPhrase(searchText, title, .4, false, true)
      || matchKeys(cache.getMedia(id), searchText, ['title.userPreferred', 'title.english', 'title.romaji', 'title.native', 'synonyms'], .4))
    || [])
}

/**
 * Deduplicates a batch of incoming notifications,
 * preferring torrent entries when there is a conflict for the same id/episode/dub key
 *
 * @param {Object[]} notifications
 * @returns {Object[]}
 */
export function dedupe(notifications) {
  const map = new Map()
  for (const notification of notifications) {
    const key = `${notification.id}-${notification.episode}-${notification.dub}`
    const existing = map.get(key)
    if (!existing || (notification.click_action === 'TORRENT' && existing.click_action !== 'TORRENT')) {
      map.set(key, notification)
    }
  }
  return Array.from(map.values())
}

/**
 * Returns a new notifications array with notification merged in according
 * to rules for delayed overrides, torrent deduping, and auto-read handling
 *
 * @param {Object[]} existing
 * @param {Object} notification
 * @returns {Object[]}
 */
export function upsert(existing, notification) {
  // Remove conflicting delayed/non-delayed entries
  const filterDelayed = existing.filter((n) => {
    if (notification.delayed) return !(n.id === notification.id && n.episode === notification.episode && n.dub === true && n.click_action === 'PLAY') // If the new notification is delayed, remove all matching notifications
    else return !(n.id === notification.id && n.episode === notification.episode && n.delayed === true) // If the new notification is not delayed, remove any existing delayed notifications
  })
  // Skip if a torrent notification already covers this episode (prevents duplicate notifications)
  const hasTorrent =
    filterDelayed.findIndex(
      (n) =>
        n.id === notification.id &&
        ((n.episode === notification.episode && (n.season || 0) === (notification.season || 0)) ||
          (n.format === 'MOVIE' && notification.format === 'MOVIE')) &&
        n.dub === notification.dub &&
        n.click_action === 'TORRENT'
    ) !== -1
  if (hasTorrent) return filterDelayed
  const filtered = filterDelayed.filter(
    (n) =>
      n.id !== notification.id ||
      n.episode !== notification.episode ||
      n.dub !== notification.dub ||
      n.click_action === 'TORRENT'
  )
  // Auto-mark as read if the user has already watched this episode
  const cachedMedia = cache.getMedia(notification?.id)
  if (isValidNumber(notification.episode) && (cachedMedia?.mediaListEntry?.status === 'COMPLETED' || (cachedMedia?.mediaListEntry?.progress || -1) >= (!isValidNumber(notification.season) ? notification.episode : cachedMedia?.episodes))) {
    notification.read = true
  }
  if (!notification.uid) notification.uid = generateRandomHexCode(8)
  return sort([notification, ...filtered])
}

/**
 * Mark notifications as read based on media progress
 *
 * @param {Object[]} notifications
 * @param {{ id: number, episode: number, season?: number }} media
 * @returns {Object[]}
 */
export function markAsRead(notifications, media) {
  return notifications.map((existing) => {
    if (existing.id === media.id && (media.episode >= existing.episode || (isValidNumber(existing.season) && media.episode >= media.episodes))) {
      existing.read = true
    }
    return existing
  })
}

/**
 * Split into local (full) and system (trimmed, max 20 to prevent flooding the system)
 *
 * @param {Object[]} notifications
 * @returns {{ localNotifications: Object[], systemNotifications: Object[] }}
 */
export function splitLocalAndSystem(notifications) {
  const localNotifications = []
  const systemNotifications = []
  for (const notification of notifications) {
    const { button, activation, ...localDetails } = notification
    localNotifications.push(localDetails)
    if (settings.value.systemNotify && (button?.length || activation)) {
      const systemDetails = {}
      for (const key of SYSTEM_KEYS) {
        if (key in notification) systemDetails[key] = notification[key]
      }
      systemNotifications.push(systemDetails)
    }
  }
  return {
    localNotifications,
    systemNotifications: systemNotifications.sort((a, b) => (b.timestamp || 0) - (a.timestamp || 0)).slice(0, 20)
  }
}

/**
 * Returns a set of boolean status flags for a notification
 *
 * @param {Object} notification
 * @param {import('@/modules/providers/anilist/al.d.ts').Media} media
 * @returns {{ delayed: boolean, announcement: boolean, repeating: boolean, notWatching: boolean, behind: boolean, completed: boolean }}
 */
export function getFlags(notification, media) {
  const delayed = notification.delayed
  const announcement = notification.click_action === 'VIEW' && !delayed
  const repeating = media?.mediaListEntry?.status === 'REPEATING'
  const notWatching =
    !announcement && !delayed
    && (!media?.mediaListEntry?.progress || (media?.mediaListEntry?.progress === 0 && (media?.mediaListEntry?.status !== 'CURRENT' || !repeating) && media?.mediaListEntry?.status !== 'COMPLETED'))
  const behind =
    Helper.isAuthorized() && !announcement && !delayed
    && isValidNumber(notification.episode) && notification.episode - 1 >= 1 && media?.mediaListEntry?.status !== 'COMPLETED'
    && (media?.mediaListEntry?.progress || -1) < (!isValidNumber(notification.season) ? notification.episode : media?.episodes) - 1
  const completed =
    !announcement && !delayed && !notWatching && !behind && isValidNumber(notification.episode)
    && (media?.mediaListEntry?.status === 'COMPLETED' || media?.mediaListEntry?.progress >= (!isValidNumber(notification.season) ? notification.episode : media?.episodes))
  return { delayed, announcement, repeating, notWatching, behind, completed }
}