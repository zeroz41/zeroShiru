// Node's `events` for the browser build: matroska-metadata (debrid subtitle
// parsing) extends EventEmitter at module scope, so an empty stub is fatal on
// boot — the class declaration throws before anything renders. Only what its
// consumers use, which is the classic on/once/off/emit surface.
export class EventEmitter {
  #listeners = new Map()

  on (event, listener) {
    let list = this.#listeners.get(event)
    if (!list) this.#listeners.set(event, list = [])
    list.push(listener)
    return this
  }

  once (event, listener) {
    const wrapped = (...args) => {
      this.off(event, wrapped)
      listener.apply(this, args)
    }
    wrapped.listener = listener
    return this.on(event, wrapped)
  }

  off (event, listener) {
    const list = this.#listeners.get(event)
    if (!list) return this
    const index = list.findIndex(entry => entry === listener || entry.listener === listener)
    if (index !== -1) list.splice(index, 1)
    if (!list.length) this.#listeners.delete(event)
    return this
  }

  emit (event, ...args) {
    const list = this.#listeners.get(event)
    if (!list?.length) return false
    for (const listener of [...list]) listener.apply(this, args)
    return true
  }

  removeAllListeners (event) {
    if (event == null) this.#listeners.clear()
    else this.#listeners.delete(event)
    return this
  }

  listenerCount (event) {
    return this.#listeners.get(event)?.length ?? 0
  }

  addListener (event, listener) { return this.on(event, listener) }
  removeListener (event, listener) { return this.off(event, listener) }
  setMaxListeners () { return this }
}

export default EventEmitter
