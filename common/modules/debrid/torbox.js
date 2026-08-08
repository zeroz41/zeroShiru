// relative import keeps this module loadable under plain Node for API tests
import DebridService, { DebridError } from './service.js'

/**
 * TorBox stub, see https://api-docs.torbox.app/
 * Untested skeleton kept out of the settings menu until someone with an account
 * implements and verifies it. The relevant endpoints are:
 * - GET  /user/me                        -> account and plan for validate()
 * - GET  /torrents/mylist                -> account torrents for listCachedHashes()
 * - GET  /torrents/checkcached?hash=     -> TorBox still offers a real cache check
 * - POST /torrents/createtorrent         -> add a magnet
 * - GET  /torrents/requestdl?torrent_id=&file_id= -> direct stream URL per file
 * Auth is a Bearer token like Real-Debrid, so the base request wrapper works as is.
 */
export default class TorBox extends DebridService {
  static id = 'torbox'
  static title = 'TorBox'

  async validate () {
    throw new DebridError(`${TorBox.title} support is not implemented yet`)
  }

  async listCachedHashes () {
    throw new DebridError(`${TorBox.title} support is not implemented yet`)
  }

  async resolve (magnet, opts) {
    throw new DebridError(`${TorBox.title} support is not implemented yet`)
  }
}
