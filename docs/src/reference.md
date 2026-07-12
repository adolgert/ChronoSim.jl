```@meta
CurrentModule = ChronoSim
```

# Reference

This page lists every documented name in ChronoSim and its
`ObservedState` submodule. The names a model uses directly are the event
interface (`SimEvent`, `precondition`, `enable`, `reenable`, `fire!`,
`isimmediate`), the generator macros (`@precondition`, `@conditionsfor`,
`@reactto`, `@fragment`, `@domain`), the state macros and containers
(`@observedphysical`, `@keyedby`, `ObservedArray`, `ObservedVector`,
`ObservedMatrix`, `ObservedDict`, `ObservedSet`, `Param`), the simulation
itself (`SimulationFSM`, `run`), and the diagnostics
(`derivation_report`, `check_derivation_coverage`,
`collect_generation_stats`, `generation_stats`,
`reset_generation_stats!`). Everything else documented here is
infrastructure that the manual pages mention in passing.

```@index
```

## ChronoSim

```@autodocs
Modules = [ChronoSim]
```

## ChronoSim.ParticleFilter

Latent-state inference over a partially observed model: the bootstrap
particle filter, built entirely on the public verbs `advance!`, `clone`, and
`rekey_streams!`. See the module docstring for the design and the usage
sketch.

```@autodocs
Modules = [ChronoSim.ParticleFilter]
```

## ChronoSim.ObservedState

```@autodocs
Modules = [ChronoSim.ObservedState]
```
