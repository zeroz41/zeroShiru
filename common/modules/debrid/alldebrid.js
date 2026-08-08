// relative import keeps this module loadable under plain Node for API tests
import DebridService, { DebridError } from './service.js'

/**
 * AllDebrid stub, see https://docs.alldebrid.com/
 * Untested skeleton kept out of the settings menu until someone with an account
 * implements and verifies it. The relevant endpoints are:
 * - GET  /user?apikey=            -> account and premium status for validate()
 * - GET  /magnet/status?apikey=   -> account magnets for listCachedHashes()
 * - GET  /magnet/upload?apikey=&magnets[]= -> add a magnet, `instant` flags cache state
 * - GET  /link/unlock?apikey=&link=        -> direct stream URL per file
 * Note: AllDebrid authenticates through a query parameter instead of a header.
 */
export default class AllDebrid extends DebridService {
  static id = 'alldebrid'
  static title = 'AllDebrid'

  async validate () {
    throw new DebridError(`${AllDebrid.title} support is not implemented yet`)
  }

  async listCachedHashes () {
    throw new DebridError(`${AllDebrid.title} support is not implemented yet`)
  }

  async resolve (magnet, opts) {
    throw new DebridError(`${AllDebrid.title} support is not implemented yet`)
  }
}
