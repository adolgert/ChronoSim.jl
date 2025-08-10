# ChronoSim.jl Framework Architecture

## Core Components and Data Flow

```mermaid
graph TD
    subgraph Framework
        TS[Tracked State]
        EG[Event Generation]
        TU[Transition Updates]
        TJS[Trajectory Sampling]
        
        TU -->|fire!| TS
        TS -->|changes| EG
        EG -->|possible events| TU
        TJS -->|next event| TU
    end
    
    style TU fill:#f9f,stroke:#333,stroke-width:4px
    style Framework fill:#f0f0f0,stroke:#333,stroke-width:2px
```

## Component Descriptions

- **Transition Updates**: The central orchestrator that manages event firing and state transitions
- **Tracked State**: Monitors and tracks all state changes in the physical system
- **Event Generation**: Creates new possible events based on state changes
- **Trajectory Sampling**: Selects the next event to fire based on the stochastic process

## Data Flow

1. **fire!**: Transition Updates executes state changes through the Tracked State
2. **changes**: Tracked State reports what changed to Event Generation
3. **possible events**: Event Generation provides new/updated events to Transition Updates
4. **next event**: Trajectory Sampling selects which event fires next from the available events
