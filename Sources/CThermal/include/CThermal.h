#ifndef CTHERMAL_H
#define CTHERMAL_H

// Reads on-die temperature sensors via IOKit's HID event system.
// Works on Apple Silicon and Intel, no special privileges required.
//
//   temps[]     filled with °C readings
//   names       flat buffer of maxCount * nameStride bytes; each sensor's
//               name is written null-terminated at names + i*nameStride
//   returns     number of sensors written (0 if unsupported)
int thermal_read(double *temps, char *names, int nameStride, int maxCount);

// Reads AppleSMC temperature keys used by common Mac health monitors.
// Sensor names are written as "SMC <key>".
int smc_thermal_read(double *temps, char *names, int nameStride, int maxCount);

#endif
