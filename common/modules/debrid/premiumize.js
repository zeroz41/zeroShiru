// relative import keeps this module loadable under plain Node for API tests
import DebridService from './service.js'

/**
 * Premiumize template, see https://www.premiumize.me/api
 *
 * Implementation template: the base class already provides authentication, rate
 * limiting, typed errors and clear not-implemented reporting, so adding support
 * means writing `validate`, `listCachedHashes`, `resolve` and `checkCachedBatch` here
 * and flipping `available` to true. Nothing outside this file has to change. Useful endpoints:
 * - GET  /account/info      -> account and premium status for validate()
 * - GET  /transfer/list     -> account transfers for listCachedHashes()
 * - GET  /cache/check       -> Premiumize still offers a real cache check (`items[]=`)
 * - POST /transfer/directdl -> direct stream URLs for a magnet in one call (`src=`)
 */
export default class Premiumize extends DebridService {
  static id = 'premiumize'
  static title = 'Premiumize'
  static auth = 'query'
  // /cache/check answers for many hashes at once, so badges cost one request
  static cacheCheck = 'batch'
}
