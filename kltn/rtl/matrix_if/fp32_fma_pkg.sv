`timescale 1ns/1ps
package fp32_fma_pkg;
	// Synthesizable bit-vector arithmetic. No real/shortreal or vendor IP.
	typedef struct packed {
		logic sign;
		logic signed [9:0] exp;
		logic [23:0] sig;
		logic zero, inf, nan, snan;
	} unpack_t;

	typedef struct packed {
		logic special;
		logic [31:0] bits;
		logic [4:0] flags;
	} special_t;

	typedef struct packed {
		logic sign;
		logic signed [9:0] exp;
		logic [55:0] mag;
	} sum_t;

	typedef struct packed {
		logic [31:0] bits;
		logic [4:0] flags; // NV DZ OF UF NX
	} result_t;

	function automatic unpack_t unpack(input logic [31:0] x);
		unpack_t u;
		logic [23:0] normalized;
		logic [4:0] distance;
		u = '0;
		u.sign = x[31];
		u.zero = (x[30:0] == 0);
		u.inf = (x[30:23] == 255) && (x[22:0] == 0);
		u.nan = (x[30:23] == 255) && (x[22:0] != 0);
		u.snan = u.nan && !x[22];
		u.exp = (x[30:23] == 0) ? -10'sd126 : $signed({2'b0,x[30:23]}) - 10'sd127;
		u.sig = {x[30:23] != 0, x[22:0]};
		// Five binary normalization steps, then ONE exponent subtraction.
		// The old repeated shift/decrement loop cascaded 23 exponent updates.
		normalized = u.sig;
		distance = '0;
		if (normalized[23:8] == 0) begin normalized = normalized << 16; distance[4] = 1; end
		if (normalized[23:16] == 0) begin normalized = normalized << 8; distance[3] = 1; end
		if (normalized[23:20] == 0) begin normalized = normalized << 4; distance[2] = 1; end
		if (normalized[23:22] == 0) begin normalized = normalized << 2; distance[1] = 1; end
		if (!normalized[23]) begin normalized = normalized << 1; distance[0] = 1; end
		if (!u.zero) begin
			u.sig = normalized;
			u.exp = u.exp - $signed({5'b0,distance});
		end
		return u;
	endfunction

	function automatic special_t specials(input unpack_t a, b, c);
		special_t s;
		logic invalid_product, product_inf, ps;
		s = '0;
		ps = a.sign ^ b.sign;
		invalid_product = (a.inf && b.zero) || (b.inf && a.zero);
		product_inf = (a.inf || b.inf) && !a.nan && !b.nan && !invalid_product;
		s.flags[4] = a.snan || b.snan || c.snan || invalid_product ||
					(product_inf && c.inf && (ps != c.sign));
			if (a.nan || b.nan || c.nan || s.flags[4]) begin
				s.special = 1;
				s.bits = 32'h7fc00000;
			end else if (product_inf || c.inf) begin
				s.special = 1;
				s.bits = {product_inf ? ps : c.sign, 8'hff, 23'b0};
			end
		return s;
	endfunction

	function automatic logic [55:0] shift_jam(input logic [55:0] x, input integer distance);
		logic [55:0] y;
		y = x;
		if (distance >= 56) begin
			y = {55'b0, |x};
		end else if (distance > 0) begin
			// Constant-size reduction per barrel stage. Jamming is associative;
			// include the retained LSB in each reduction to preserve earlier jams.
			for (int stage = 0; stage < 6; stage++) begin
				if (distance[stage])
					y = (y >> (1 << stage)) | {55'b0, |(y << (55 - (1 << stage)))};
			end
		end
		return y;
	endfunction

	function automatic sum_t align_add(
		input logic [47:0] product,
		input unpack_t a, b, c,
		input logic [2:0] rm
	);
		sum_t s;
		logic [55:0] p, q;
		logic ps;
		logic signed [9:0] ep, eq;
		s = '0;
		ps = a.sign ^ b.sign;
		ep = a.exp + b.exp;
		eq = c.exp;
		// Leading bit at bit 54; bit 55 is the addition carry.
		// Exact 48-bit product plus >=7 low alignment/rounding bits.
		if (product[47]) begin
			p = {1'b0,product,7'b0};
			ep = ep + 10'sd1;
		end else begin
			p = {product,8'b0};
		end
		q = {1'b0,c.sig,31'b0};
		if (p == 0) ep = eq;
		if (q == 0) eq = ep;
		if (ep > eq) begin
			q = shift_jam(q, int'(ep) - int'(eq));
			s.exp = ep;
		end 
		else begin
			p = shift_jam(p, int'(eq) - int'(ep));
			s.exp = eq;
		end
		if (ps == c.sign) begin
			s.mag = p + q;
			s.sign = ps;
		end 
		else if (p > q) begin
			s.mag = p - q;
			s.sign = ps;
		end 
		else if (q > p) begin
			s.mag = q - p;
			s.sign = c.sign;
		end 
		else begin
			s.mag = 0;
			s.sign = (rm == 3'd2); // Exact cancellation: -0 only for RDN.
		end
		return s;
	endfunction

	function automatic logic round_increment(
		input logic sign, lsb, guard_bit, sticky,
		input logic [2:0] rm
		);
		case (rm)
			3'd0: return guard_bit && (sticky || lsb);       // RNE
			3'd1: return 1'b0;                              // RTZ
			3'd2: return sign && (guard_bit || sticky);      // RDN
			3'd3: return !sign && (guard_bit || sticky);     // RUP
			3'd4: return guard_bit;                         // RMM
			default: return 1'b0; // Controller rejects reserved modes.
		endcase
	endfunction

	function automatic result_t round_pack(input sum_t in_sum, input special_t special, input logic [2:0] rm);
		result_t r;
		logic [55:0] mag;
		logic signed [9:0] exp;
		logic [24:0] sig;
		logic [7:0] exp_field;
		logic guard_bit, sticky, inexact, increment, to_inf, tiny;
		r = '0;
		mag = in_sum.mag;
		exp = in_sum.exp;
			if (special.special) begin
				r.bits = special.bits;
				r.flags = special.flags;
			end else if (mag == 0) begin
				r.bits = {in_sum.sign,31'b0};
			end else begin
				if (mag[55]) begin
					mag = shift_jam(mag,1);
					exp = exp + 10'sd1;
				end
				for (int i = 0; i < 54; i++) begin
					if (!mag[54]) begin
						mag = mag << 1;
						exp = exp - 10'sd1;
					end
				end
				// Detect tininess after rounding to 24 bits with an unbounded
				// exponent, before shifting into the subnormal output range.
				// Only a rounding carry at exp=-127 can reach min-normal.
				increment = round_increment(in_sum.sign, mag[31], mag[30], |mag[29:0], rm);
				tiny = (exp < -10'sd126) &&
					!((exp == -10'sd127) && (&mag[54:31]) && increment);
				// Keep mag unrounded: the flag calculation must not double-round the value.
				if (exp < -10'sd126) begin
					mag = shift_jam(mag, -126 - int'(exp));
					exp = -10'sd126;
				end
				sig = {1'b0,mag[54:31]};
				guard_bit = mag[30];
				sticky = |mag[29:0];
				inexact = guard_bit | sticky;
				increment = round_increment(in_sum.sign, sig[0], guard_bit, sticky, rm);
				sig = sig + {24'b0,increment};
				if (sig[24]) begin
					sig = sig >> 1;
					exp = exp + 10'sd1;
				end
				if (exp > 10'sd127) begin
					to_inf = (rm == 0) || (rm == 4) ||
							((rm == 2) && in_sum.sign) || ((rm == 3) && !in_sum.sign);
					r.bits = to_inf ? {in_sum.sign,8'hff,23'b0} : {in_sum.sign,8'hfe,23'h7fffff};
					r.flags = 5'b00101;
				end else begin
					exp_field = sig[23] ? 8'($unsigned(exp + 10'sd127)) : 8'd0;
					r.bits = {in_sum.sign,exp_field,sig[22:0]};
					r.flags[0] = inexact;
					r.flags[1] = inexact && tiny;
				end
			end
		return r;
	endfunction

	// Balanced leading-zero detector: six levels instead of a priority chain.
	function automatic logic [5:0] lzc55(input logic [54:0] x);
		logic [5:0] n;
		logic [63:0] probe;
		probe = {x,9'b0};
		n = '0;
		if (probe[63:32] == 0) begin probe = probe << 32; n[5] = 1; end
		if (probe[63:48] == 0) begin probe = probe << 16; n[4] = 1; end
		if (probe[63:56] == 0) begin probe = probe << 8; n[3] = 1; end
		if (probe[63:60] == 0) begin probe = probe << 4; n[2] = 1; end
		if (probe[63:62] == 0) begin probe = probe << 2; n[1] = 1; end
		n[0] = !probe[63];
		return (x == 0) ? 6'd55 : n;
	endfunction

	function automatic result_t round_pack_fast(input sum_t in_sum, input special_t special, input logic [2:0] rm);
		result_t r;
		logic [55:0] mag;
		logic signed [9:0] exp;
		logic signed [10:0] exp_norm, room;
		logic [5:0] lz;
		logic [24:0] sig;
		logic [7:0] exp_field;
		logic guard_bit, sticky, inexact, increment, to_inf, tiny;
		r = '0;
		mag = in_sum.mag;
		exp = in_sum.exp;
		if (special.special) begin
			r.bits = special.bits;
			r.flags = special.flags;
		end 
		else if (mag == 0) begin
			r.bits = {in_sum.sign,31'b0};
		end 
		else begin
			if (mag[55]) begin
				mag = shift_jam(mag,1);
				exp = exp + 10'sd1;
			end
			lz = lzc55(mag[54:0]);
			exp_norm = 11'(exp) - 11'($signed({5'b0,lz}));
			room = 11'(exp) + 11'sd126;
			tiny = 1'b0;
			if (exp_norm >= -11'sd126) begin
				mag = mag << lz;
				exp = 10'(exp_norm);
			end 
			else begin
				if (room >= 0) 
					mag = mag << room[5:0];
				else 
					mag = shift_jam(mag, -int'(room));
				// mag now equals the subnormal-aligned value.
				if (exp_norm == -11'sd127)
					tiny = !((&mag[53:30]) && round_increment(in_sum.sign, mag[30], mag[29], |mag[28:0], rm));
				else
					tiny = 1'b1;
				exp = -10'sd126;
			end
			sig = {1'b0,mag[54:31]};
			guard_bit = mag[30];
			sticky = |mag[29:0];
			inexact = guard_bit | sticky;
			increment = round_increment(in_sum.sign, sig[0], guard_bit, sticky, rm);
			sig = sig + {24'b0,increment};
			if (sig[24]) begin
				sig = sig >> 1;
				exp = exp + 10'sd1;
			end
			if (exp > 10'sd127) begin
				to_inf = (rm == 0) || (rm == 4) ||
						((rm == 2) && in_sum.sign) || ((rm == 3) && !in_sum.sign);
				r.bits = to_inf ? {in_sum.sign,8'hff,23'b0} : {in_sum.sign,8'hfe,23'h7fffff};
				r.flags = 5'b00101;
			end 
			else begin
				exp_field = sig[23] ? 8'($unsigned(exp + 10'sd127)) : 8'd0;
				r.bits = {in_sum.sign,exp_field,sig[22:0]};
				r.flags[0] = inexact;
				r.flags[1] = inexact && tiny;
			end
		end
		return r;
	endfunction
endpackage
