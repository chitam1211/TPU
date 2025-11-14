import struct
import math

# =============================================================================
# CÁC HÀM TIỆN ÍCH CHUYỂN ĐỔI KIỂU DỮ LIỆU
# =============================================================================

# --- Float <-> Bits ---
def bits_to_float32(bits):
    try: return struct.unpack('f', struct.pack('I', bits & 0xFFFFFFFF))[0]
    except: return 0.0

def float_to_bits32(f):
    try: return struct.unpack('I', struct.pack('f', f))[0]
    except OverflowError: return 0x7f800000 if f > 0 else 0xff800000
    except: return 0

def bits_to_float16(bits):
    """
    Chuyển đổi 16-bit pattern thành float16 value.
    Implement IEEE 754 half-precision manually.
    """
    bits = bits & 0xFFFF
    
    # Extract components
    sign = (bits >> 15) & 0x1
    exponent = (bits >> 10) & 0x1F
    mantissa = bits & 0x3FF
    
    # Handle special cases
    if exponent == 0:
        if mantissa == 0:
            return -0.0 if sign else 0.0
        else:
            # Subnormal number
            value = (mantissa / 1024.0) * (2 ** -14)
            return -value if sign else value
    elif exponent == 0x1F:
        if mantissa == 0:
            return float('-inf') if sign else float('inf')
        else:
            return float('nan')
    else:
        # Normal number
        value = (1.0 + mantissa / 1024.0) * (2 ** (exponent - 15))
        return -value if sign else value

def float_to_bits16(f):
    """
    Chuyển đổi float value thành 16-bit FP16 pattern.
    """
    if math.isnan(f):
        return 0x7E00  # NaN
    
    if math.isinf(f):
        return 0xFC00 if f < 0 else 0x7C00  # ±Inf
    
    # Get sign
    sign = 1 if f < 0 else 0
    f = abs(f)
    
    if f == 0.0:
        return 0x8000 if sign else 0x0000
    
    # Convert to float32 bits first
    bits32 = float_to_bits32(f if not sign else -f)
    sign = (bits32 >> 31) & 0x1
    exp32 = ((bits32 >> 23) & 0xFF) - 127  # Unbias
    mant32 = bits32 & 0x7FFFFF
    
    # Adjust to FP16 range
    exp16 = exp32 + 15  # Rebias for FP16
    
    # Handle overflow
    if exp16 >= 0x1F:
        return (sign << 15) | 0x7C00  # Infinity
    
    # Handle underflow
    if exp16 <= 0:
        # Subnormal or zero
        if exp16 < -10:
            return sign << 15  # Zero
        # Subnormal
        mant16 = (0x400 | (mant32 >> 13)) >> (1 - exp16)
        return (sign << 15) | mant16
    
    # Normal number
    mant16 = mant32 >> 13  # Truncate to 10 bits
    return (sign << 15) | (exp16 << 10) | mant16

# --- BFloat16 Converters ---
def float_to_bfloat16(f):
    """Chuyển đổi float32 sang bfloat16 (16-bit)."""
    try:
        bits32 = float_to_bits32(f)
        # BFloat16 = Lấy 16 bit cao của Float32
        # Làm tròn: kiểm tra bit thứ 16 (từ phải sang)
        rounding_bias = (bits32 >> 16) & 0x1
        bfloat16_bits = (bits32 + (rounding_bias << 15)) >> 16
        return bfloat16_bits & 0xFFFF
    except:
        return 0

def bfloat16_to_float(bits):
    """Chuyển đổi bfloat16 (16-bit) sang float32."""
    bits &= 0xFFFF
    # BFloat16 -> Float32: Dịch trái 16 bit
    bits32 = bits << 16
    return bits_to_float32(bits32)

# --- FP8 Simplified Converters ---
def float_to_bits8_e4m3(f):
    if math.isnan(f): return 0b10000000
    if math.isinf(f): return 0b01111000 if f > 0 else 0b11111000
    bits32 = float_to_bits32(f); sign = (bits32 >> 31) & 0x1
    if (bits32 & 0x7FFFFFFF) == 0: return 0b10000000 if sign else 0b00000000
    exponent32 = ((bits32 >> 23) & 0xFF) - 127; mantissa32 = bits32 & 0x7FFFFF
    bias8 = 7; exponent8 = exponent32 + bias8
    if exponent8 >= 15: return 0b11111000 if sign else 0b01111000
    if exponent8 <= 0: return 0b10000000 if sign else 0b00000000
    mantissa8 = (mantissa32 >> 20) & 0x7
    if (mantissa32 >> 19) & 0x1:
        mantissa8 += 1
        if mantissa8 > 0x7: mantissa8 = 0; exponent8 += 1
        if exponent8 >= 15: return 0b11111000 if sign else 0b01111000
    return (sign << 7) | (exponent8 << 3) | mantissa8

def float_to_bits8_e5m2(f):
    if math.isnan(f): return 0b10000000
    if math.isinf(f): return 0b01111100 if f > 0 else 0b11111100
    bits32 = float_to_bits32(f); sign = (bits32 >> 31) & 0x1
    if (bits32 & 0x7FFFFFFF) == 0: return 0b10000000 if sign else 0b00000000
    exponent32 = ((bits32 >> 23) & 0xFF) - 127; mantissa32 = bits32 & 0x7FFFFF
    bias8 = 15; exponent8 = exponent32 + bias8
    if exponent8 >= 31: return 0b11111100 if sign else 0b01111100
    if exponent8 <= 0: return 0b10000000 if sign else 0b00000000
    mantissa8 = (mantissa32 >> 21) & 0x3
    if (mantissa32 >> 20) & 0x1:
        mantissa8 += 1
        if mantissa8 > 0x3: mantissa8 = 0; exponent8 += 1
        if exponent8 >= 31: return 0b11111100 if sign else 0b01111100
    return (sign << 7) | (exponent8 << 2) | mantissa8

# --- (THÊM MỚI) Hàm chuyển đổi ngược 8-bit ---
def bits_to_float8_e4m3(bits):
    """Chuyển đổi bit pattern 8-bit (E4M3) thành float."""
    bits &= 0xFF
    sign = (bits >> 7) & 0x1
    exponent = (bits >> 3) & 0xF
    mantissa = bits & 0x7
    
    if exponent == 0 and mantissa == 0: return -0.0 if sign else 0.0
    if exponent == 15 and mantissa == 0: return float('-inf') if sign else float('inf')
    if exponent == 15 and mantissa != 0: return float('nan')

    # Giá trị chuẩn (bias 7)
    val = (1 + (mantissa / 8.0)) * (2.0 ** (exponent - 7))
    return -val if sign else val

def bits_to_float8_e5m2(bits):
    """Chuyển đổi bit pattern 8-bit (E5M2) thành float."""
    bits &= 0xFF
    sign = (bits >> 7) & 0x1
    exponent = (bits >> 2) & 0x1F
    mantissa = bits & 0x3

    if exponent == 0 and mantissa == 0: return -0.0 if sign else 0.0
    if exponent == 31 and mantissa == 0: return float('-inf') if sign else float('inf')
    if exponent == 31 and mantissa != 0: return float('nan')
    
    # Giá trị chuẩn (bias 15)
    val = (1 + (mantissa / 4.0)) * (2.0 ** (exponent - 15))
    return -val if sign else val

# --- Bits -> Signed Int ---
def bits_to_signed_int32(bits):
    bits &= 0xFFFFFFFF; return bits - 0x100000000 if bits & 0x80000000 else bits
def bits_to_signed_int16(bits):
    val = bits & 0xFFFF; return val - 0x10000 if val & 0x8000 else val
def bits_to_signed_int8(bits):
    val = bits & 0xFF; return val - 0x100 if val & 0x80 else val

# --- Int <-> Bits ---
def bits_to_int32(bits): return bits_to_signed_int32(bits)
def int_to_bits32(i): return int(i) & 0xFFFFFFFF