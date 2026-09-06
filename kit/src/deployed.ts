// AUTO-SYNCED — do not edit by hand.
// Written by scripts/sync-abis.mjs from the Foundry artifacts in contracts/out.
// Refresh with: npm run sync-abis

/** Live Lucid deployment, copied from contracts/deployed.json when this file was written. */
export const deployed = {
  chainId: 50312,
  /** ERC-1167 master copy every user desk is cloned from. Never call it directly. */
  deskImplementation: '0x45a2b60529861F50966939124d1e56b488D07a55',
  brain: '0xE817dEAD27a4c492eBBeeAB4211e0206dFA79B02',
  /** Sole owner of every reactivity subscription; must hold >= 32 SOMI to keep them alive. */
  router: '0x4FBB2DBC34b74e8837E1Bd2dC83D8dCDfD859f2f',
  factory: '0x588393057fEd5Fd69F21e38527d80Ad57888BE8A',
  keeper: '0x95D9f6a45295670c787b0e18589E2762450A47b7',
  relay: '0x62d4B3814c9959769252C284Fbc87dEADca5fa91',
  /** DreamDEX venue the router is armed against. */
  venueId: '0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f',
} as const
