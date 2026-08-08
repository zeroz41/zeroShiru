// relative import keeps this module loadable under plain Node for API tests
import DebridService from './service.js'

/**
 * AllDebrid template, see https://docs.alldebrid.com/
 *
 * Implementation template: the base class already provides authentication, rate
 * limiting, typed errors and clear not-implemented reporting, so adding support
 * means writing `validate`, `listCachedHashes` and `resolve` here and flipping
 * `available` to true. Nothing outside this file has to change. Useful endpoints:
 * - GET /user          -> account and premium status for validate()
 * - GET /magnet/status -> account magnets for listCachedHashes()
 * - GET /magnet/upload -> add a magnet (`magnets[]=`), the `instant` flag reports cache state
 * - GET /link/unlock   -> direct stream URL per file (`link=`)
 */
export default class AllDebrid extends DebridService {
  static id = 'alldebrid'
  static title = 'AllDebrid'
  static auth = 'query'
}
