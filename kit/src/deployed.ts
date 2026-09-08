// AUTO-SYNCED — do not edit by hand.
// Written by scripts/sync-abis.mjs from the Foundry artifacts in contracts/out.
// Refresh with: npm run sync-abis

/** Live Lucid deployment, copied from contracts/deployed.json when this file was written. */
export const deployed = {
  chainId: 50312,
  /** ERC-1167 master copy every user desk is cloned from. Never call it directly. */
  deskImplementation: '0xa659b03e2349559f2d56D17F246e66e79467c17e',
  brain: '0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25',
  /**
   * Handles every reactivity callback, and owns the wake-up subscriptions it books itself.
   * Must hold >= 32 SOMI to keep them alive.
   */
  router: '0x6aE21a20444141552648C1f8443bAf171BCCcB99',
  /**
   * Owns the venue's `MarketCreated` subscription and names the router as its handler, on a bond
   * of its own. Absent on deployments that predate it, where the router owns that one too.
   */
  watch: '0xA0eb631bc7bD386C05Dcc1b1BFFd0021Ef1f6D3C',
  factory: '0x9c1EF0C429f1F88e8247f3539DeF8a1f8FCCEb84',
  keeper: '0x4757599dC9A5a089270373a66BEeeD6592788707',
  relay: '0xd9Eee9BE420E2CD777E55d890a940a637ed0bB7A',
  /** DreamDEX venue the router is armed against. */
  venueId: '0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f',
} as const
