/**
 * lucid-kit — a typed client for Lucid, a protocol of autonomous trading desks for DreamDEX
 * Event Contracts on Somnia.
 *
 * The kit is a library and a CLI, and deliberately nothing else. Lucid's keeper is an on-chain
 * reactivity subscription and its brain is Somnia's native agent committee, so there is no server
 * to talk to and none to run: every function here either reads the chain and the public indexer,
 * or signs one transaction and returns. Nothing in this package starts a loop you did not ask for.
 */

export * from './abis.js'
export * from './addresses.js'
export * from './client.js'
export * from './desk.js'
export * from './events.js'
export * from './markets.js'
export * from './policy.js'
export * from './protocol.js'
export * from './subscriptions.js'
