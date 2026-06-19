### architecture

for now here's a quick block diagram

    +------------------+      +------------------+      +------------------+
    | Pump Current In  | ---> |  LPC Controller  | ---> | PWM Drive Output |
    +------------------+      |  - Thresholds    |      +------------------+
                              |  - Shutdown FSM  |
    +------------------+      |  - Debounce      |      +------------------+
    | AC Zero Detect   | ---> |  - Timing Logic  | ---> | Status / Debug   |
    +------------------+      +------------------+      +------------------+

