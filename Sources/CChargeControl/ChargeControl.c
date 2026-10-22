#include "CChargeControl.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <string.h>
#include <unistd.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } SMCPowerLimit;
typedef struct { uint32_t size, type; uint8_t attributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPowerLimit power;
    SMCKeyInfo info;
    uint8_t result, status, command;
    uint32_t data;
    uint8_t bytes[32];
} SMCMessage;
_Static_assert(sizeof(SMCMessage) == 80, "AppleSMC ABI must be 80 bytes");

static uint32_t key_code(const char *s) {
    return (uint32_t)s[0] << 24 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 8 | (uint32_t)s[3];
}
static int call(io_connect_t connection, SMCMessage *input, SMCMessage *output, CellChargeControlState *state) {
    size_t size = sizeof(*output);
    kern_return_t result = IOConnectCallStructMethod(connection, 2, input, sizeof(*input), output, &size);
    state->io_error = result; state->smc_error = output->result;
    return result == KERN_SUCCESS && size == sizeof(*output) && output->result == 0;
}
static int read_key(io_connect_t connection, const char *key, uint32_t expected_size,
                    uint8_t *bytes, CellChargeControlState *state) {
    SMCMessage input = {0}, output = {0};
    input.key = key_code(key); input.command = 9; // key metadata
    if (!call(connection, &input, &output, state) || output.info.size != expected_size) return 0;
    input.info.size = expected_size; input.command = 5; memset(&output, 0, sizeof(output));
    if (!call(connection, &input, &output, state)) return 0;
    memcpy(bytes, output.bytes, expected_size); return 1;
}
static int write_key(io_connect_t connection, const char *key, uint32_t size,
                     const uint8_t *bytes, CellChargeControlState *state) {
    SMCMessage input = {0}, output = {0};
    input.key = key_code(key); input.info.size = size; input.command = 6;
    memcpy(input.bytes, bytes, size);
    return call(connection, &input, &output, state);
}
static int open_smc(io_connect_t *connection, CellChargeControlState *state) {
    memset(state, 0, sizeof(*state)); state->inhibited = -1;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    state->io_error = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return state->io_error == KERN_SUCCESS;
}
static int probe(io_connect_t connection, CellChargeControlState *state) {
    uint8_t value[4] = {0}, b = 0, c = 0;
    if (read_key(connection, "CHTE", 4, value, state)) {
        if (value[0] <= 1 && value[1] == 0 && value[2] == 0 && value[3] == 0) {
            state->backend = 1; state->inhibited = value[0]; return 1;
        }
        return 0; // Never fall back after an unrecognized modern register value.
    }
    if (read_key(connection, "CH0B", 1, &b, state) && read_key(connection, "CH0C", 1, &c, state)
        && (b == 0 || b == 2) && b == c) {
        state->backend = 2; state->inhibited = b == 2; return 1;
    }
    return 0;
}
int cell_charge_probe(CellChargeControlState *state) {
    io_connect_t connection = 0;
    if (!open_smc(&connection, state)) return 0;
    int ok = probe(connection, state); IOServiceClose(connection); return ok;
}
int cell_charge_set_inhibited(int inhibited, CellChargeControlState *state) {
    if (geteuid() != 0 || (inhibited != 0 && inhibited != 1)) {
        memset(state, 0, sizeof(*state)); state->io_error = kIOReturnNotPrivileged; return 0;
    }
    io_connect_t connection = 0;
    if (!open_smc(&connection, state)) return 0;
    int ok = probe(connection, state);
    if (!ok || state->inhibited == inhibited) { IOServiceClose(connection); return ok; }
    int backend = state->backend, original = state->inhibited;
    uint8_t desired[4] = {(uint8_t)(backend == 1 ? inhibited : inhibited * 2), 0, 0, 0};
    uint8_t prior[4] = {(uint8_t)(backend == 1 ? original : original * 2), 0, 0, 0};
    if (backend == 1) ok = write_key(connection, "CHTE", 4, desired, state);
    else {
        ok = write_key(connection, "CH0B", 1, desired, state);
        if (ok) ok = write_key(connection, "CH0C", 1, desired, state);
    }
    if (ok) ok = probe(connection, state) && state->backend == backend && state->inhibited == inhibited;
    if (!ok) {
        uint32_t error = state->io_error; uint8_t smc_error = state->smc_error;
        if (backend == 1) write_key(connection, "CHTE", 4, prior, state);
        else { write_key(connection, "CH0B", 1, prior, state); write_key(connection, "CH0C", 1, prior, state); }
        state->io_error = error; state->smc_error = smc_error;
    }
    IOServiceClose(connection); return ok;
}
