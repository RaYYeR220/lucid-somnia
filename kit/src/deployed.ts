// AUTO-SYNCED — do not edit by hand.
// Written by scripts/sync-abis.mjs from the Foundry artifacts in contracts/out.
// Refresh with: npm run sync-abis

/** Live Lucid deployment, copied from contracts/deployed.json when this file was written. */
export const deployed = {
  chainId: 50312,
  /** ERC-1167 master copy every user desk is cloned from. Never call it directly. */
  deskImplementation: '0xc54d0BaA3310F77a164D17Fe10f32a567793489E',
  brain: '0x0c640E3aFc627bEec7eDB9985696e12B50AdAd25',
  /** Sole owner of every reactivity subscription; must hold >= 32 SOMI to keep them alive. */
  router: '0x6aE21a20444141552648C1f8443bAf171BCCcB99',
  factory: '0xF82cC4219F6c7fe816155A8c3F0C9C3B1cc320eA',
  keeper: '0x4757599dC9A5a089270373a66BEeeD6592788707',
  relay: '0xd9Eee9BE420E2CD777E55d890a940a637ed0bB7A',
  /** DreamDEX venue the router is armed against. */
  venueId: '0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f',
} as const
