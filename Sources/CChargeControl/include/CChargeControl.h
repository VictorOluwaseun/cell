#ifndef CELL_CHARGE_CONTROL_H
#define CELL_CHARGE_CONTROL_H
#include <stdint.h>
#include <IOKit/IOMessage.h>
enum {
    CellPowerWillSleep = kIOMessageSystemWillSleep,
    CellPowerCanSleep = kIOMessageCanSystemSleep,
    CellPowerDidWake = kIOMessageSystemHasPoweredOn
};
typedef struct {
    int backend; // 1 = CHTE, 2 = CH0B + CH0C
    int inhibited;
    uint32_t io_error;
    uint8_t smc_error;
} CellChargeControlState;
// Read-only. Unsupported keys or unrecognized values return failure.
int cell_charge_probe(CellChargeControlState *state);
// Root-only. Only charge inhibition keys and exact known values can be written.
// Includes readback; restores the original bytes if a write fails.
int cell_charge_set_inhibited(int inhibited, CellChargeControlState *state);
#endif
