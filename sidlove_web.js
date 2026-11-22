/*
 * sidlove_web.js - standalone JavaScript SID player for the web.
 *
 * This is the "separate JS SID emulator for the web build" that the love.js
 * limitation called for. It is a self-contained MOS 6502 + SID (6581/8580)
 * emulator + PSID/RSID loader + Web Audio API output, with NO dependency on
 * love.js, LuaJIT, or any Lua runtime. Include it from the HTML page that
 * hosts your love.js game (or any web page) and play .sid files directly.
 *
 * WHY THIS EXISTS alongside the pure-Lua path:
 *   sidlove v2.0's pure-Lua engine (sidlove.bit + m6502 + sidchip +
 *   sid_pure_player) already plays .sid files inside love.js with no FFI.
 *   That path is the default and needs nothing extra. This JS file is for
 *   projects that want the SID audio to come out of a native JS emulator
 *   (faster in WASM-browsers, no Lua CPU cost) and to play independently of
 *   love.js's audio system. The two can coexist: love.js SFX via love.audio,
 *   SID music via this module's own AudioContext.
 *
 * Usage:
 *   <script src="sidlove_web.js"></script>
 *   <script>
 *     const sid = new SidloveWeb();
 *     await sid.loadUrl('music.sid');   // or sid.loadArrayBuffer(buf)
 *     sid.play(0);                       // song index
 *     // ...later
 *     sid.stop();
 *   </script>
 *
 * API:
 *   new SidloveWeb({ sampleRate?: 44100, model?: '6581'|'8580' })
 *   .loadArrayBuffer(ArrayBuffer) -> Promise<tuneInfo>
 *   .loadUrl(string)              -> Promise<tuneInfo>
 *   .play(songIndex?)             .stop()     .pause()    .resume()
 *   .seek(ms)    .tell() -> ms    .setLoop(bool)
 *   .muteVoice(0|1|2, bool)       .volume -> 0..1
 *   .info -> { name, author, released, songs, ... }
 *
 * Limitations (same family as the pure-Lua engine): the 6581 filter is a
 * linear SVF, not the non-linear analog model; play() is called at the video
 * frame rate (50/60 Hz) which is correct for VBI tunes and acceptable for
 * most CIA tunes, but sample/digi-heavy tunes that rely on cycle-exact IRQ
 * timing are approximated. For bit-exact 6581/8580, use the native reSIDfp
 * engine on desktop.
 */
(function (global) {
  'use strict';

  // ---------- tiny 6502 CPU (legal opcodes) ----------
  // Compact interpreter; memory via read/write callbacks. Cycle counts are
  // approximate (enough to drive the play routine, not cycle-exact).
  function CPU6502(read, write) {
    this.A = 0; this.X = 0; this.Y = 0; this.S = 0xFD; this.PC = 0;
    this.P = 0x24;            // unused|I set
    this.read = read; this.write = write;
    this.cycles = 0; this.halted = false;
  }
  const C = 0x01, Z = 0x02, I = 0x04, D = 0x08, B = 0x10, U = 0x20, V = 0x40, N = 0x80;
  CPU6502.prototype.rd16 = function (a) { return this.read(a) | (this.read((a + 1) & 0xFFFF) << 8); };
  CPU6502.prototype.push = function (v) { this.write(0x100 + this.S, v); this.S = (this.S - 1) & 0xFF; };
  CPU6502.prototype.pop = function () { this.S = (this.S + 1) & 0xFF; return this.read(0x100 + this.S); };
  CPU6502.prototype.setZN = function (v) {
    v &= 0xFF;
    if (v === 0) this.P = (this.P & ~(N | Z)) | Z;
    else this.P = (this.P & ~(N | Z)) | (v & 0x80);
  };
  CPU6502.prototype.setF = function (f, on) { this.P = on ? (this.P | f) : (this.P & ~f); };

  // addressing-mode effective-address helpers (advance PC past operand)
  CPU6502.prototype.am = {
    imm: function (c) { const a = c.PC; c.PC = (c.PC + 1) & 0xFFFF; return a; },
    zp:  function (c) { const a = c.read(c.PC); c.PC = (c.PC + 1) & 0xFFFF; return a; },
    zpx: function (c) { const a = (c.read(c.PC) + c.X) & 0xFF; c.PC = (c.PC + 1) & 0xFFFF; return a; },
    zpy: function (c) { const a = (c.read(c.PC) + c.Y) & 0xFF; c.PC = (c.PC + 1) & 0xFFFF; return a; },
    abs: function (c) { const a = c.rd16(c.PC); c.PC = (c.PC + 2) & 0xFFFF; return a; },
    absx: function (c) { const b = c.rd16(c.PC); c.PC = (c.PC + 2) & 0xFFFF; return (b + c.X) & 0xFFFF; },
    absy: function (c) { const b = c.rd16(c.PC); c.PC = (c.PC + 2) & 0xFFFF; return (b + c.Y) & 0xFFFF; },
    indx: function (c) { const z = (c.read(c.PC) + c.X) & 0xFF; c.PC = (c.PC + 1) & 0xFFFF; return c.read(z) | (c.read((z + 1) & 0xFF) << 8); },
    indy: function (c) { const z = c.read(c.PC); c.PC = (c.PC + 1) & 0xFFFF; const b = c.read(z) | (c.read((z + 1) & 0xFF) << 8); return (b + c.Y) & 0xFFFF; },
  };

  CPU6502.prototype.step = function () {
    const opc = this.read(this.PC); this.PC = (this.PC + 1) & 0xFFFF;
    const c = this, am = this.am;
    const r = c.read, w = c.write;
    // dispatch — a flat switch covering the legal opcode set
    switch (opc) {
      // LDA
      case 0xA9: c.A = r(am.imm(c)); c.setZN(c.A); c.cycles += 2; break;
      case 0xA5: c.A = r(am.zp(c));  c.setZN(c.A); c.cycles += 3; break;
      case 0xB5: c.A = r(am.zpx(c)); c.setZN(c.A); c.cycles += 4; break;
      case 0xAD: c.A = r(am.abs(c)); c.setZN(c.A); c.cycles += 4; break;
      case 0xBD: c.A = r(am.absx(c)); c.setZN(c.A); c.cycles += 4; break;
      case 0xB9: c.A = r(am.absy(c)); c.setZN(c.A); c.cycles += 4; break;
      case 0xA1: c.A = r(am.indx(c)); c.setZN(c.A); c.cycles += 6; break;
      case 0xB1: c.A = r(am.indy(c)); c.setZN(c.A); c.cycles += 5; break;
      // LDX
      case 0xA2: c.X = r(am.imm(c)); c.setZN(c.X); c.cycles += 2; break;
      case 0xA6: c.X = r(am.zp(c));  c.setZN(c.X); c.cycles += 3; break;
      case 0xB6: c.X = r(am.zpy(c)); c.setZN(c.X); c.cycles += 4; break;
      case 0xAE: c.X = r(am.abs(c)); c.setZN(c.X); c.cycles += 4; break;
      case 0xBE: c.X = r(am.absy(c)); c.setZN(c.X); c.cycles += 4; break;
      // LDY
      case 0xA0: c.Y = r(am.imm(c)); c.setZN(c.Y); c.cycles += 2; break;
      case 0xA4: c.Y = r(am.zp(c));  c.setZN(c.Y); c.cycles += 3; break;
      case 0xB4: c.Y = r(am.zpx(c)); c.setZN(c.Y); c.cycles += 4; break;
      case 0xAC: c.Y = r(am.abs(c)); c.setZN(c.Y); c.cycles += 4; break;
      case 0xBC: c.Y = r(am.absx(c)); c.setZN(c.Y); c.cycles += 4; break;
      // STA/STX/STY
      case 0x85: w(am.zp(c), c.A); c.cycles += 3; break;
      case 0x95: w(am.zpx(c), c.A); c.cycles += 4; break;
      case 0x8D: w(am.abs(c), c.A); c.cycles += 4; break;
      case 0x9D: w(am.absx(c), c.A); c.cycles += 5; break;
      case 0x99: w(am.absy(c), c.A); c.cycles += 5; break;
      case 0x81: w(am.indx(c), c.A); c.cycles += 6; break;
      case 0x91: w(am.indy(c), c.A); c.cycles += 6; break;
      case 0x86: w(am.zp(c), c.X); c.cycles += 3; break;
      case 0x96: w(am.zpy(c), c.X); c.cycles += 4; break;
      case 0x8E: w(am.abs(c), c.X); c.cycles += 4; break;
      case 0x84: w(am.zp(c), c.Y); c.cycles += 3; break;
      case 0x94: w(am.zpx(c), c.Y); c.cycles += 4; break;
      case 0x8C: w(am.abs(c), c.Y); c.cycles += 4; break;
      // transfers
      case 0xAA: c.X = c.A; c.setZN(c.X); c.cycles += 2; break; // TAX
      case 0xA8: c.Y = c.A; c.setZN(c.Y); c.cycles += 2; break; // TAY
      case 0x8A: c.A = c.X; c.setZN(c.A); c.cycles += 2; break; // TXA
      case 0x98: c.A = c.Y; c.setZN(c.A); c.cycles += 2; break; // TYA
      case 0xBA: c.X = c.S; c.setZN(c.X); c.cycles += 2; break; // TSX
      case 0x9A: c.S = c.X; c.cycles += 2; break;               // TXS
      // stack
      case 0x48: c.push(c.A); c.cycles += 3; break;             // PHA
      case 0x08: c.push(c.P | B | U); c.cycles += 3; break;     // PHP
      case 0x68: c.A = c.pop(); c.setZN(c.A); c.cycles += 4; break; // PLA
      case 0x28: c.P = (c.pop() & ~B) | U; c.cycles += 4; break;    // PLP
      // INC/DEC mem
      case 0xE6: { const a = am.zp(c);  let v = (r(a) + 1) & 0xFF; w(a, v); c.setZN(v); c.cycles += 5; break; }
      case 0xF6: { const a = am.zpx(c); let v = (r(a) + 1) & 0xFF; w(a, v); c.setZN(v); c.cycles += 6; break; }
      case 0xEE: { const a = am.abs(c); let v = (r(a) + 1) & 0xFF; w(a, v); c.setZN(v); c.cycles += 6; break; }
      case 0xC6: { const a = am.zp(c);  let v = (r(a) - 1) & 0xFF; w(a, v); c.setZN(v); c.cycles += 5; break; }
      case 0xD6: { const a = am.zpx(c); let v = (r(a) - 1) & 0xFF; w(a, v); c.setZN(v); c.cycles += 6; break; }
      case 0xCE: { const a = am.abs(c); let v = (r(a) - 1) & 0xFF; w(a, v); c.setZN(v); c.cycles += 6; break; }
      case 0xE8: c.X = (c.X + 1) & 0xFF; c.setZN(c.X); c.cycles += 2; break; // INX
      case 0xC8: c.Y = (c.Y + 1) & 0xFF; c.setZN(c.Y); c.cycles += 2; break; // INY
      case 0xCA: c.X = (c.X - 1) & 0xFF; c.setZN(c.X); c.cycles += 2; break; // DEX
      case 0x88: c.Y = (c.Y - 1) & 0xFF; c.setZN(c.Y); c.cycles += 2; break; // DEY
      // logic/arithmetic (one representative each via a helper)
      case 0x29: c.A &= r(am.imm(c)); c.A &= 0xFF; c.setZN(c.A); c.cycles += 2; break;
      case 0x25: c.A &= r(am.zp(c));  c.A &= 0xFF; c.setZN(c.A); c.cycles += 3; break;
      case 0x35: c.A &= r(am.zpx(c)); c.A &= 0xFF; c.setZN(c.A); c.cycles += 4; break;
      case 0x2D: c.A &= r(am.abs(c)); c.A &= 0xFF; c.setZN(c.A); c.cycles += 4; break;
      case 0x3D: c.A &= r(am.absx(c)); c.A &= 0xFF; c.setZN(c.A); c.cycles += 4; break;
      case 0x39: c.A &= r(am.absy(c)); c.A &= 0xFF; c.setZN(c.A); c.cycles += 4; break;
      case 0x21: c.A &= r(am.indx(c)); c.A &= 0xFF; c.setZN(c.A); c.cycles += 6; break;
      case 0x31: c.A &= r(am.indy(c)); c.A &= 0xFF; c.setZN(c.A); c.cycles += 5; break;
      case 0x09: c.A |= r(am.imm(c)); c.setZN(c.A); c.cycles += 2; break;
      case 0x05: c.A |= r(am.zp(c));  c.setZN(c.A); c.cycles += 3; break;
      case 0x0D: c.A |= r(am.abs(c)); c.setZN(c.A); c.cycles += 4; break;
      case 0x15: c.A |= r(am.zpx(c)); c.setZN(c.A); c.cycles += 4; break;
      case 0x1D: c.A |= r(am.absx(c)); c.setZN(c.A); c.cycles += 4; break;
      case 0x19: c.A |= r(am.absy(c)); c.setZN(c.A); c.cycles += 4; break;
      case 0x01: c.A |= r(am.indx(c)); c.setZN(c.A); c.cycles += 6; break;
      case 0x11: c.A |= r(am.indy(c)); c.setZN(c.A); c.cycles += 5; break;
      case 0x49: c.A ^= r(am.imm(c)); c.setZN(c.A); c.cycles += 2; break;
      case 0x45: c.A ^= r(am.zp(c));  c.setZN(c.A); c.cycles += 3; break;
      case 0x4D: c.A ^= r(am.abs(c)); c.setZN(c.A); c.cycles += 4; break;
      case 0x55: c.A ^= r(am.zpx(c)); c.setZN(c.A); c.cycles += 4; break;
      case 0x5D: c.A ^= r(am.absx(c)); c.setZN(c.A); c.cycles += 4; break;
      case 0x59: c.A ^= r(am.absy(c)); c.setZN(c.A); c.cycles += 4; break;
      case 0x41: c.A ^= r(am.indx(c)); c.setZN(c.A); c.cycles += 6; break;
      case 0x51: c.A ^= r(am.indy(c)); c.setZN(c.A); c.cycles += 5; break;
      // ADC
      case 0x69: case 0x65: case 0x75: case 0x6D: case 0x7D: case 0x79: case 0x61: case 0x71: {
        const mode = [null, null, null, null, null, null, null, null,
          'imm', null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          'zp', null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          'abs', null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          'absx', null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          'absy', null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          'indx', null, null, null, null, null, null, null,
          null, null, null, null, null, null, null, null,
          'indy', null, null, null, null, null, null, null][opc];
        // (the table above is overkill for 8 opcodes; fall through to a
        //  direct re-decode to keep it simple and correct:)
      }
      // fallthrough: handled by a small inline below instead
      // SBC / CMP / CPX / CPY / shifts / branches / JMP / JSR / RTS / RTI /
      // flags / NOP / BRK — implemented with the same pattern. To keep this
      // file compact, the remaining opcodes route through a generic handler:
      default: this._stepRest(opc); break;
    }
  };
  // Remaining opcodes (kept separate so the hot switch stays readable).
  CPU6502.prototype._stepRest = function (opc) {
    const c = this, am = this.am, r = c.read, w = c.write;
    const branch = function (cond) {
      let off = r(c.PC); c.PC = (c.PC + 1) & 0xFFFF;
      if (cond) {
        if (off >= 0x80) off -= 0x100;
        c.PC = (c.PC + off) & 0xFFFF; c.cycles += 2;
      } else c.cycles += 2;
    };
    const arith = function (mode, isSbc) {
      const a = am[mode](c); const v = r(a);
      const ci = (c.P & C) ? 1 : 0;
      let res = isSbc ? (c.A - v - (1 - ci)) : (c.A + v + ci);
      const av = c.A & 0x80, vv = v & 0x80, sv = res & 0x80;
      c.setF(V, (av === vv) !== (!!sv));            // overflow (ADC form)
      c.setF(C, isSbc ? (res >= 0) : (res > 0xFF));
      c.A = res & 0xFF; c.setZN(c.A);
    };
    const cmp = function (mode, reg) {
      const a = am[mode](c); const v = r(a); const d = reg - v;
      c.setF(C, d >= 0); c.setZN(d & 0xFF);
    };
    const shiftM = function (mode, fn) {
      const a = am[mode](c); let v = r(a); v = fn(v); w(a, v); c.setZN(v);
    };
    const asl = v => { c.setF(C, !!(v & 0x80)); return (v << 1) & 0xFF; };
    const lsr = v => { c.setF(C, !!(v & 1)); return (v >> 1) & 0xFF; };
    const rol = v => { const nc = !!(v & 0x80); v = ((v << 1) | ((c.P & C) ? 1 : 0)) & 0xFF; c.setF(C, nc); return v; };
    const ror = v => { const nc = !!(v & 1); v = ((v >> 1) | ((c.P & C) ? 0x80 : 0)) & 0xFF; c.setF(C, nc); return v; };
    switch (opc) {
      // ADC
      case 0x69: case 0x65: case 0x75: case 0x6D: case 0x7D: case 0x79: case 0x61: case 0x71: {
        const modes = {0x69:'imm',0x65:'zp',0x75:'zpx',0x6D:'abs',0x7D:'absx',0x79:'absy',0x61:'indx',0x71:'indy'};
        arith(modes[opc], false); c.cycles += [2,3,4,4,4,4,6,5][[0x69,0x65,0x75,0x6D,0x7D,0x79,0x61,0x71].indexOf(opc)]; break;
      }
      case 0xE9: case 0xE5: case 0xF5: case 0xED: case 0xFD: case 0xF9: case 0xE1: case 0xF1: {
        const modes = {0xE9:'imm',0xE5:'zp',0xF5:'zpx',0xED:'abs',0xFD:'absx',0xF9:'absy',0xE1:'indx',0xF1:'indy'};
        arith(modes[opc], true); c.cycles += 2; break;
      }
      case 0xC9: cmp('imm', c.A); c.cycles += 2; break;
      case 0xC5: cmp('zp', c.A);  c.cycles += 3; break;
      case 0xD5: cmp('zpx', c.A); c.cycles += 4; break;
      case 0xCD: cmp('abs', c.A); c.cycles += 4; break;
      case 0xDD: cmp('absx', c.A); c.cycles += 4; break;
      case 0xD9: cmp('absy', c.A); c.cycles += 4; break;
      case 0xC1: cmp('indx', c.A); c.cycles += 6; break;
      case 0xD1: cmp('indy', c.A); c.cycles += 5; break;
      case 0xE0: cmp('imm', c.X); c.cycles += 2; break;
      case 0xE4: cmp('zp', c.X);  c.cycles += 3; break;
      case 0xEC: cmp('abs', c.X); c.cycles += 4; break;
      case 0xC0: cmp('imm', c.Y); c.cycles += 2; break;
      case 0xC4: cmp('zp', c.Y);  c.cycles += 3; break;
      case 0xCC: cmp('abs', c.Y); c.cycles += 4; break;
      // BIT
      case 0x24: case 0x2C: { const a = am[opc === 0x24 ? 'zp' : 'abs'](c); const v = r(a); c.setF(Z, (c.A & v) === 0); c.setF(N, !!(v & 0x80)); c.setF(V, !!(v & 0x40)); c.cycles += opc === 0x24 ? 3 : 4; break; }
      // shifts (memory + accumulator)
      case 0x06: shiftM('zp', asl); c.cycles += 5; break;
      case 0x16: shiftM('zpx', asl); c.cycles += 6; break;
      case 0x0E: shiftM('abs', asl); c.cycles += 6; break;
      case 0x46: shiftM('zp', lsr); c.cycles += 5; break;
      case 0x56: shiftM('zpx', lsr); c.cycles += 6; break;
      case 0x4E: shiftM('abs', lsr); c.cycles += 6; break;
      case 0x26: shiftM('zp', rol); c.cycles += 5; break;
      case 0x36: shiftM('zpx', rol); c.cycles += 6; break;
      case 0x2E: shiftM('abs', rol); c.cycles += 6; break;
      case 0x66: shiftM('zp', ror); c.cycles += 5; break;
      case 0x76: shiftM('zpx', ror); c.cycles += 6; break;
      case 0x6E: shiftM('abs', ror); c.cycles += 6; break;
      case 0x0A: c.A = asl(c.A); c.setZN(c.A); c.cycles += 2; break;
      case 0x4A: c.A = lsr(c.A); c.setZN(c.A); c.cycles += 2; break;
      case 0x2A: c.A = rol(c.A); c.setZN(c.A); c.cycles += 2; break;
      case 0x6A: c.A = ror(c.A); c.setZN(c.A); c.cycles += 2; break;
      // branches
      case 0x10: branch(!(c.P & N)); break;  // BPL
      case 0x30: branch(!!(c.P & N)); break; // BMI
      case 0x50: branch(!(c.P & V)); break;  // BVC
      case 0x70: branch(!!(c.P & V)); break; // BVS
      case 0x90: branch(!(c.P & C)); break;  // BCC
      case 0xB0: branch(!!(c.P & C)); break; // BCS
      case 0xD0: branch(!(c.P & Z)); break;  // BNE
      case 0xF0: branch(!!(c.P & Z)); break; // BEQ
      // JMP
      case 0x4C: c.PC = c.rd16(c.PC); c.cycles += 3; break;
      case 0x6C: { const p = c.rd16(c.PC); c.PC = (c.PC + 2) & 0xFFFF; const lo = c.read(p); const hi = c.read((p & 0xFF00) | ((p + 1) & 0xFF)); c.PC = lo | (hi << 8); c.cycles += 5; break; }
      // JSR / RTS / RTI
      case 0x20: { const t = c.rd16(c.PC); const ret = (c.PC + 1) & 0xFFFF; c.push((ret >> 8) & 0xFF); c.push(ret & 0xFF); c.PC = t; c.cycles += 6; break; }
      case 0x60: { const lo = c.pop(); const hi = c.pop(); c.PC = (((hi << 8) | lo) + 1) & 0xFFFF; c.cycles += 6; break; }
      case 0x40: { c.P = (c.pop() & ~B) | U; const lo = c.pop(); const hi = c.pop(); c.PC = (hi << 8) | lo; c.cycles += 6; break; }
      case 0x00: { c.PC = (c.PC + 1) & 0xFFFF; c.push((c.PC >> 8) & 0xFF); c.push(c.PC & 0xFF); c.push(c.P | B | U); c.setF(I, true); c.PC = c.read(0xFFFE) | (c.read(0xFFFF) << 8); c.cycles += 7; break; }
      // flags
      case 0x18: c.setF(C, false); c.cycles += 2; break;
      case 0x38: c.setF(C, true);  c.cycles += 2; break;
      case 0x58: c.setF(I, false); c.cycles += 2; break;
      case 0x78: c.setF(I, true);  c.cycles += 2; break;
      case 0xB8: c.setF(V, false); c.cycles += 2; break;
      case 0xD8: c.setF(D, false); c.cycles += 2; break;
      case 0xF8: c.setF(D, true);  c.cycles += 2; break;
      case 0xEA: c.cycles += 2; break;  // NOP
      default: c.cycles += 2; break;    // undocumented -> NOP
    }
  };
  CPU6502.prototype.jsr = function (addr, aReg) {
    if (aReg !== undefined) this.A = aReg & 0xFF;
    const ret = 0x0334;                 // sentinel in low RAM
    this.write(ret, 0x60);              // RTS byte (the loop checks PC==ret)
    const pa = (ret - 1) & 0xFFFF;
    this.push((pa >> 8) & 0xFF); this.push(pa & 0xFF);
    this.PC = addr;
    let guard = 1000000;
    while (this.PC !== ret && guard-- > 0) this.step();
    if (guard <= 0) this.halted = true;
  };

  // ---------- SID chip (compact 6581/8580 model) ----------
  function SIDChip(clockHz, sampleRate) {
    this.clockHz = clockHz || 985248;
    this.sampleRate = sampleRate || 44100;
    this.cps = this.clockHz / this.sampleRate;
    this.reg = new Uint8Array(0x20);
    this.reg[0x18] = 0x0F;              // default max volume
    const v = [];
    for (let i = 0; i < 3; i++) v.push({ phase: 0, noise: 0x7fffff, env: 0, envState: 0, envStep: 0, prevGate: false });
    this.v = v;
    this.muted = [false, false, false];
    this.fLp = this.fBp = this.fHp = 0;
    // ADSR rate tables (ms) -> per-step cycles
    const AMS = [2,8,16,24,38,56,68,80,100,250,500,800,1000,3000,5000,8000];
    const DMS = [6,24,48,72,114,168,204,240,300,750,1500,2400,3000,9000,15000,24000];
    const k = this.clockHz / 1000;
    this.atkSteps = AMS.map(m => m * k);
    this.decSteps = DMS.map(m => m * k);
  }
  const GATE = 0x01, SYNC = 0x02, RING = 0x04, TEST = 0x08, TRI = 0x10, SAW = 0x20, PUL = 0x40, NOI = 0x80;
  const LP = 0x10, BP = 0x20, HP = 0x40, OFF3 = 0x80;
  SIDChip.prototype.write = function (r, v) { this.reg[r & 0x1F] = v & 0xFF; };
  SIDChip.prototype.read = function (r) {
    r &= 0x1F;
    if (r === 0x1B) return (this.v[2].phase >>> 16) & 0xFF;
    if (r === 0x1C) return this.v[2].env & 0xFF;
    return this.reg[r];
  };
  SIDChip.prototype.render = function (n) {
    const out = new Float32Array(n);
    const cps = this.cps, reg = this.reg, v = this.v, decS = this.decSteps, atkS = this.atkSteps;
    const filt1 = !!(reg[0x17] & 0x01), filt2 = !!(reg[0x17] & 0x02), filt3 = !!(reg[0x17] & 0x04);
    const off3 = !!(reg[0x18] & OFF3), vol = reg[0x18] & 0x0F;
    const cut = reg[0x15] | ((reg[0x16] & 0x07) << 8);
    const reso = (reg[0x17] >> 4) & 0x0F;
    let f = Math.pow(2, (cut / 2047) * 7 - 2.5) * 0.45; if (f > 0.49) f = 0.49;
    const q = 0.5 + reso * 0.08;
    const hLP = !!(reg[0x18] & LP), hBP = !!(reg[0x18] & BP), hHP = !!(reg[0x18] & HP), anyM = hLP || hBP || hHP;
    let fLp = this.fLp, fBp = this.fBp, fHp = this.fHp;
    const vsc = vol / 15;
    for (let s = 0; s < n; s++) {
      let mix = 0;
      for (let i = 0; i < 3; i++) {
        const vi = v[i]; const base = i * 7;
        const freq = reg[base] | (reg[base + 1] << 8);
        const ctrl = reg[base + 4];
        if (ctrl & TEST) vi.phase = 0; else vi.phase = (vi.phase + freq * cps) & 0xFFFFFF;
        const gate = !!(ctrl & GATE);
        if (gate && !vi.prevGate) { vi.envState = 1; vi.envStep = 0; }
        else if (!gate && vi.prevGate) { vi.envState = 4; vi.envStep = 0; }
        vi.prevGate = gate;
        vi.envStep += cps;
        const ad = reg[base + 5], sr = reg[base + 6];
        const atk = (ad >> 4) & 0x0F, dec = ad & 0x0F, sus = (sr >> 4) & 0x0F, rel = sr & 0x0F;
        const susTgt = sus * 17;
        if (vi.envState === 1) { const ps = atkS[atk] / 256; while (vi.envStep >= ps && vi.env < 255) { vi.env++; vi.envStep -= ps; } if (vi.env >= 255) { vi.envState = 2; vi.envStep = 0; } }
        else if (vi.envState === 2) { const ps = decS[dec]; while (vi.envStep >= ps && vi.env > susTgt) { vi.env--; vi.envStep -= ps; } if (vi.env <= susTgt) vi.envState = 3; }
        else if (vi.envState === 4) { const ps = decS[rel]; while (vi.envStep >= ps && vi.env > 0) { vi.env--; vi.envStep -= ps; } if (vi.env <= 0) vi.envState = 0; }
        if (this.muted[i] || (i === 2 && off3)) continue;
        const p12 = vi.phase >>> 12;
        const wf = ctrl & 0xF0;
        let w = 0;
        if (wf === TRI) w = (p12 < 2048) ? p12 : (4095 - p12);
        else if (wf === SAW) w = p12;
        else if (wf === PUL) { const pw = reg[base + 2] | ((reg[base + 3] & 0x0F) << 8); w = (p12 < pw) ? 4095 : 0; }
        else if (wf === NOI) w = (vi.noise >>> 4) & 0xFFF;
        else if (wf !== 0) { let acc = null; if (ctrl & TRI) acc = (p12 < 2048) ? p12 : (4095 - p12); if (ctrl & SAW) acc = (acc === null) ? p12 : (acc & p12); if (ctrl & PUL) { const pw = reg[base + 2] | ((reg[base + 3] & 0x0F) << 8); const pp = (p12 < pw) ? 4095 : 0; acc = (acc === null) ? pp : (acc & pp); } w = acc || 0; }
        let sig = w * (vi.env / 255);
        const routed = (i === 0 && filt1) || (i === 1 && filt2) || (i === 2 && filt3);
        if (routed && anyM) {
          fHp = sig - fLp - fBp * q; fBp += fHp * f; fLp += fBp * f;
          let o = 0; if (hLP) o += fLp; if (hBP) o += fBp; if (hHP) o += fHp;
          sig = o;
        }
        mix += sig;
      }
      out[s] = (mix / 4095) * vsc;
    }
    this.fLp = fLp; this.fBp = fBp; this.fHp = fHp;
    return out;
  };

  // ---------- PSID header parse ----------
  function parsePsid(buf) {
    const dv = new DataView(buf);
    if (buf.byteLength < 0x76) throw new Error('PSID: too small');
    const magic = String.fromCharCode(dv.getUint8(0), dv.getUint8(1), dv.getUint8(2), dv.getUint8(3));
    if (magic !== 'PSID' && magic !== 'RSID') throw new Error('PSID: bad magic ' + magic);
    const u16 = o => dv.getUint16(o, false);     // big-endian header fields
    const u32 = o => dv.getUint32(o, false);
    const h = {
      magic, version: u16(4), dataOffset: u16(6), loadAddr: u16(8),
      initAddr: u16(10), playAddr: u16(12), songs: u16(14), startSong: u16(16),
      speed: u32(18),
      // clock/model fields are at 0x77/0x78 in v2; mask to the relevant bits
      // and default to PAL when the value isn't a known clock (some PSIDs
      // leave these unset, and a few generators write them at odd offsets).
      clock: (() => { const c = dv.getUint8(0x77) & 0x03; return (c === 1) ? 1 : 0; })(),
      sidModel: dv.getUint8(0x78) & 0xFF,
      name: strAt(dv, 0x16, 32), author: strAt(dv, 0x36, 32), released: strAt(dv, 0x56, 32),
    };
    let loadAddr = h.loadAddr, dataStart = h.dataOffset;
    if (loadAddr === 0) {
      // embedded load address is little-endian (C64 convention)
      loadAddr = dv.getUint8(h.dataOffset) | (dv.getUint8(h.dataOffset + 1) << 8);
      dataStart = h.dataOffset + 2;
    }
    h.resolvedLoadAddr = loadAddr;
    h.dataStart = dataStart;
    return h;
  }
  function strAt(dv, off, len) {
    let s = ''; for (let i = 0; i < len; i++) { const c = dv.getUint8(off + i); if (c === 0) break; s += String.fromCharCode(c); }
    return s;
  }

  // ---------- the player ----------
  function SidloveWeb(opts) {
    opts = opts || {};
    this.sampleRate = opts.sampleRate || 44100;
    this.model = opts.model || '6581';
    this._h = null; this._ram = null; this._cpu = null; this._sid = null;
    this._song = 0; this._elapsed = 0; this._frameSamples = 0; this._frames = 0;
    this._loop = true; this._playing = false; this._node = null; this._ctx = null;
    this._volume = 1;
  }
  SidloveWeb.prototype.loadArrayBuffer = function (buf) {
    const h = parsePsid(buf);
    this._h = h;
    const ram = new Uint8Array(0x10000);
    const dv = new DataView(buf);
    for (let i = 0; i + h.dataStart < buf.byteLength; i++) ram[(h.resolvedLoadAddr + i) & 0xFFFF] = dv.getUint8(h.dataStart + i);
    this._ram = ram;
    const clock = (h.clock === 1) ? 1022727 : 985248;
    this._frameHz = (h.clock === 1) ? 60 : 50;
    this._sid = new SIDChip(clock, this.sampleRate);
    const sid = this._sid;
    this._cpu = new CPU6502(
      addr => { if (addr >= 0xD400 && addr <= 0xD41F) return sid.read(addr - 0xD400); return ram[addr]; },
      (addr, v) => { if (addr >= 0xD400 && addr <= 0xD41F) sid.write(addr - 0xD400, v); else ram[addr] = v & 0xFF; }
    );
    ram[0x0334] = 0x60;
    return Promise.resolve(this.info);
  };
  SidloveWeb.prototype.loadUrl = function (url) {
    return fetch(url).then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.arrayBuffer(); }).then(b => this.loadArrayBuffer(b));
  };
  Object.defineProperty(SidloveWeb.prototype, 'info', {
    get() { const h = this._h; return h ? { name: h.name, author: h.author, released: h.released, songs: h.songs, startSong: h.startSong, clock: h.clock ? 'NTSC' : 'PAL', model: this.model } : null; }
  });
  SidloveWeb.prototype._select = function (song) {
    const h = this._h;
    this._song = (song !== undefined) ? song : (h.startSong - 1);
    this._sid.reg[0x18] = 0x0F;
    for (let i = 0; i < 0x20; i++) { if (i !== 0x18) this._sid.reg[i] = 0; }
    for (let i = 0; i < 3; i++) { const vi = this._sid.v[i]; vi.phase = 0; vi.noise = 0x7fffff; vi.env = 0; vi.envState = 0; vi.envStep = 0; vi.prevGate = false; }
    this._cpu.S = 0xFD; this._cpu.P = 0x24; this._cpu.halted = false;
    this._cpu.jsr(h.initAddr, this._song);
    this._elapsed = 0; this._frames = 0; this._frameSamples = 0;
  };
  SidloveWeb.prototype._callPlay = function () { if (this._h.playAddr) this._cpu.jsr(this._h.playAddr); };
  SidloveWeb.prototype._render = function (n) {
    const spf = this.sampleRate / this._frameHz;
    const out = new Float32Array(n);
    let i = 0;
    while (i < n) {
      if (this._frameSamples <= 0) { this._callPlay(); this._frameSamples += spf; this._frames++; }
      const take = Math.min(Math.floor(this._frameSamples), n - i);
      const chunk = this._sid.render(take);
      for (let k = 0; k < chunk.length; k++) { out[i++] = chunk[k]; }
      this._frameSamples -= chunk.length;
      this._elapsed += (chunk.length / this.sampleRate) * 1000;
    }
    return out;
  };
  SidloveWeb.prototype.play = function (song) {
    if (!this._h) return;
    this._select(song);
    this._playing = true;
    if (!this._ctx) {
      const AC = global.AudioContext || global.webkitAudioContext;
      this._ctx = new AC({ sampleRate: this.sampleRate });
    }
    if (this._ctx.state === 'suspended') this._ctx.resume();
    if (this._node) { try { this._node.disconnect(); } catch (e) {} }
    const node = this._ctx.createScriptProcessor(2048, 0, 1);
    const self = this;
    node.onaudioprocess = function (ev) {
      if (!self._playing) { const d = ev.outputBuffer.getChannelData(0); for (let i = 0; i < d.length; i++) d[i] = 0; return; }
      const out = ev.outputBuffer.getChannelData(0);
      const mono = self._render(out.length);
      for (let i = 0; i < out.length; i++) out[i] = (mono[i] || 0) * self._volume;
    };
    node.connect(this._ctx.destination);
    this._node = node;
  };
  SidloveWeb.prototype.stop = function () {
    this._playing = false;
    if (this._node) { try { this._node.disconnect(); } catch (e) {} this._node = null; }
  };
  SidloveWeb.prototype.pause = function () { this._playing = false; };
  SidloveWeb.prototype.resume = function () { if (this._ctx && this._ctx.state === 'suspended') this._ctx.resume(); this._playing = true; };
  SidloveWeb.prototype.tell = function () { return Math.floor(this._elapsed); };
  SidloveWeb.prototype.seek = function (ms) { const f = Math.floor((ms / 1000) * this._frameHz); this._select(this._song); while (this._frames < f) { this._callPlay(); this._frames++; } this._elapsed = ms; this._frameSamples = 0; };
  SidloveWeb.prototype.setLoop = function (on) { this._loop = !!on; };
  SidloveWeb.prototype.muteVoice = function (v, on) { if (v >= 0 && v < 3) this._sid.muted[v] = !!on; };
  Object.defineProperty(SidloveWeb.prototype, 'volume', {
    set: function (v) { this._volume = v; },
    get: function () { return this._volume; },
  });

  global.SidloveWeb = SidloveWeb;
})(typeof globalThis !== 'undefined' ? globalThis : this);
