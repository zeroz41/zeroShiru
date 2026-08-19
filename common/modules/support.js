// feature support list, overridden per environment, global

export const SUPPORTS = {
  offscreenRender: true,
  update: true,
  // renderer compositing modes, for the Linux stacks where the fast path fails.
  // The host fills the list in; an empty one hides the setting
  graphics: true,
  discord: true,
  keybinds: true,
  isAndroid: false,
  maxSeeding: 10,
  externalPlayer: true,
  permamentNAT: true
}
