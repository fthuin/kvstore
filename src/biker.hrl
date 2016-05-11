-define(ROUNDLENGTH, 10000).
-define(DISTANCETOCOVER, 100).

-record(state, {pid, roundnbr, decision, nbrofplayers, position, distancetocover, energy, speed, roundlength}).
