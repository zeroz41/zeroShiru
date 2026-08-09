// relative import keeps this module loadable under plain Node for API tests
import DebridService from './service.js'

/**
 * TorBox template, see https://api-docs.torbox.app/
 *
 * Implementation template: the base class already provides authentication, rate
 * limiting, typed errors and clear not-implemented reporting, so adding support
 * means writing `validate`, `listCachedHashes`, `resolve` and `checkCachedBatch` here
 * and flipping `available` to true. Nothing outside this file has to change. TorBox uses a
 * Bearer token like Real-Debrid, so the inherited `auth` default already fits.
 * Useful endpoints:
 * - GET  /user/me                -> account and plan for validate()
 * - GET  /torrents/mylist        -> account torrents for listCachedHashes()
 * - GET  /torrents/checkcached   -> a real cache check (`hash=`), so badges can be exact
 * - POST /torrents/createtorrent -> add a magnet
 * - GET  /torrents/requestdl     -> direct stream URL per file (`torrent_id=&file_id=`)
 */
export default class TorBox extends DebridService {
  static id = 'torbox'
  static title = 'TorBox'
  // /torrents/checkcached answers for many hashes at once, so badges cost one request
  static cacheCheck = 'batch'
}
