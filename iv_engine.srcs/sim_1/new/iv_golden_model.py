"""
iv_golden_model.py
Bit-accurate Python golden model for the 18-stage hyperbolic CORDIC pipeline.
Replicates the RTL in iv_cordic_pipeline.sv using 32-bit signed fixed-point
arithmetic (Q8.24 format).

Called by dpi_bridge.c via Python C-API during UVM simulation.
"""

def _to_s32(val):
    """Truncate arbitrary Python int to 32-bit signed."""
    val = val & 0xFFFFFFFF
    return val - 0x100000000 if val >= 0x80000000 else val

def _asr32(val, shift):
    """32-bit arithmetic right shift (sign-extending)."""
    val = _to_s32(val)
    return val >> shift          # Python >> on negatives is arithmetic

def calculate_full_iv(S, K, C, r, T):
    """
    Replicate the 18-stage pipelined hyperbolic CORDIC exactly.

    Parameters (all 32-bit signed ints passed from C via DPI):
        S  -> CORDIC x_in
        K  -> CORDIC y_in
        C  -> CORDIC z_in
        r  -> bit 0 selects mode: 1 = Rotation, 0 = Vectoring
        T  -> unused in Phase 1

    Returns:
        int: CORDIC x_out (32-bit signed)
    """
    # Shift schedule (matches RTL: repeated stages at index 4 & 13)
    SHIFTS = [1, 2, 3, 4, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 13, 14, 15, 16]

    # atanh look-up table in Q8.24 (copied from RTL localparam)
    ATANH_LUT = [
        9213465, 4285819, 2091932, 1039863, 1039863,
         519097,  259345,  129643,   64817,   32408,
          16204,    8102,    4051,    2025,    2025,
           1013,     506,     253,
    ]

    x = _to_s32(S)
    y = _to_s32(K)
    z = _to_s32(C)
    mode = r & 1

    for i in range(18):
        shift = SHIFTS[i]
        atanh = ATANH_LUT[i]

        # Direction decision (matches corrected RTL)
        if mode == 1:                       # Rotation: drive z -> 0
            d = 1 if z >= 0 else 0
        else:                               # Vectoring: drive y -> 0
            d = 1 if y < 0 else 0

        y_shifted = _asr32(y, shift)
        x_shifted = _asr32(x, shift)

        if d == 1:
            x_new = _to_s32(x + y_shifted)
            y_new = _to_s32(y + x_shifted)
            z_new = _to_s32(z - atanh)
        else:
            x_new = _to_s32(x - y_shifted)
            y_new = _to_s32(y - x_shifted)
            z_new = _to_s32(z + atanh)

        x, y, z = x_new, y_new, z_new

    return _to_s32(x)


# ------------------------------------------------------------------
# Quick self-test (run standalone: python iv_golden_model.py)
# ------------------------------------------------------------------
if __name__ == "__main__":
    Q24 = 1 << 24                     # 1.0 in Q8.24
    # Test: rotation mode with x=1.0, y=0, z=0.5
    # Expected: x_out ~ K_n * cosh(0.5) where K_n ~ 0.8282
    x_in  = Q24                        # 1.0
    y_in  = 0
    z_in  = Q24 // 2                   # 0.5
    result = calculate_full_iv(x_in, y_in, z_in, 1, 0)
    # K_n * cosh(0.5) ~ 0.8282 * 1.1276 ~ 0.9339
    print(f"Input:  x={x_in}, y={y_in}, z={z_in}")
    print(f"Output: x_out={result}  ({result / Q24:.6f} in float)")
    import math
    expected = 0.82816 * math.cosh(0.5)
    print(f"Analytic (K_n*cosh): {expected:.6f}")
