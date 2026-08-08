// relative import keeps this module loadable under plain Node for API tests
import DebridService, { DebridError } from './service.js'

/**
 * Premiumize stub, see https://www.premiumize.me/api
 * Untested skeleton kept out of the settings menu until someone with an account
 * implements and verifies it. The relevant endpoints are:
 * - GET  /account/info?apikey=      -> account and premium status for validate()
 * - GET  /transfer/list?apikey=     -> account transfers for listCachedHashes()
 * - GET  /cache/check?apikey=&items[]= -> Premiumize still offers a real cache check
 * - POST /transfer/directdl?apikey=&src= -> direct stream URLs for a magnet in one call
 * Note: Premiumize authenticates through a query parameter instead of a header.
 */
export default class Premiumize extends DebridService {
  static id = 'premiumize'
  static title = 'Premiumize'

  async validate () {
    throw new DebridError(`${Premiumize.title} support is not implemented yet`)
  }

  async listCachedHashes () {
    throw new DebridError(`${Premiumize.title} support is not implemented yet`)
  }

  async resolve (magnet, opts) {
    throw new DebridError(`${Premiumize.title} support is not implemented yet`)
  }
}
