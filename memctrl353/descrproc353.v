/*
** -----------------------------------------------------------------------------**
** descrproc353.v
**
**
** Copyright (C) 2002-2010 Elphel, Inc.
** Author: Andrey Filippov
**
** -----------------------------------------------------------------------------**
**  This file is part of X333
**  X333 is free software - hardware description language (HDL) code.
** 
**  This program is free software: you can redistribute it and/or modify
**  it under the terms of the GNU General Public License as published by
**  the Free Software Foundation, either version 3 of the License, or
**  (at your option) any later version.
**
**  This program is distributed in the hope that it will be useful,
**  but WITHOUT ANY WARRANTY; without even the implied warranty of
**  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
**  GNU General Public License for more details.
**
**  You should have received a copy of the GNU General Public License
**  along with this program.  If not, see <http://www.gnu.org/licenses/>.
** -----------------------------------------------------------------------------**
**
*/
module descrproc (clk,      // SDRAM clock (120MHz?) phase0
                  ia,       // internal 4-bit address bus (fast - directly from I/O pads)
                  as,       // 4 bit address to select descriptor address and data word (3 bits)
                  am,       // switching between ia (async read) and as (sync write)
                  mcs,      // (decoded address) - write to one of 16 loc in descriptor memory (from CPU) and some extra commands
                  mdi,      // 18-bit data from CPU to descriptor memory
                  mdo,      // 32-bit data from descriptor memory to CPU (lower 16 - same as written, high 16 - readonly current state
                           // now - overlapping as state needs 20 bits.
                  chStIn,   // data channel start (generated by arbiter)
                  chInit,   // will be generated by arbiter, arbiter will not wait for confiramtion
                  chNum,   // 2-bit channel number. Is set by arbiter at chStIn or chInit (is zero when SDRAM is disabled)
                  chStOut,   // channel start output (to sequencer). Delayed by 6 tacts from chStIn
                  sa,      // start address of the block
                  sfa,     // start address of a frame - ugly hack to roll over the last (extra) 4 lines of a frame
                           // to the beginning of a frame - used in photofinish mode.
                  rovr,    // roll over mode (photofinish, (cntrl0[13]==1) && (mode== 1, last line of tiles)
                  mode,      // mode (0 - 256x1, 1 - 18x9)
                  WnR,      // write /not read
                  nBuf,      // buffer page to use (now - 2 bits)
                  seq_par, // [5:0] sequencer parameters
                           // dual-purpose parameter. In 256x1 mode specifies (5 LSBs) number of 8-word long groups to r/w (0- all 32),
                           // actually for all but 0 (when exactly 256 words are xfered) will transfer one word more
                            // In 18x9 mode specifies bits 13:8 of address increment between lines
                  mancmd,   // 18-bit manual command for SDRAM (when writig data to RO location 4'h3
                  enSDRAM,   // output that enables SDRAM auto access. When 0 - only manual commands are allowed.  Written at address 0'h7, bit 0
                  enRefresh,// written at address 0'h7, bit 1
                  enXfer,   // enable trasfer through channel
                  chReqInit,// request (to arbiter) init channel
                  nextFrame,// (level) generated before actual block is filled - needed to be combined with the pulse from buffer control
                  confirmRead, // confirm channel read (level OK), needed after start or roll over, FIFO will not be filled otherwise - should be sync to clk
                  bonded,      //[3:0] - channel bonded with the other (just for channel 2), make it TIG
                  restart_en,  // enable restarting selected channels
                  restart,      // reinitialize channels (posedge-sensitive, masked by enXfer0
                  nextBlocksEn     //[3:0] // enable read blocks to FIFO. disabled when init or roll over, enable by confirmRead
                  );   // data to descriptor memory bit matching wnr (write-not-read)
   input            clk;//,wclk;
   input    [ 3:0]   ia;
   input    [ 3:0]   as;
   input    [ 3:0]   am;
   input            mcs;
   input    [17:0]   mdi;
   output [31:0]   mdo;
   input            chStIn;
   input            chInit;
   input    [ 1:0]   chNum;
   output         chStOut;
   output [24:3]   sa;
   output [24:8]   sfa; // start frame address - photofinish hack
   output         rovr;   // roll over mode (photofinish, cntrl0[12]==1, last line of tiles)
   output         mode;
   output         WnR;
   output [ 1:0]   nBuf;
   output [ 5:0]  seq_par;
   output [17:0]   mancmd;
   output         enSDRAM;
   output         enRefresh;
   output [ 3:0]   enXfer;
   output [ 3:0]   chReqInit;
   output [ 3:0]   nextFrame;
   input  [ 3:0]  confirmRead; // confirm channel read (level OK), needed after start or roll over, FIFO will not be filled otherwise
   output [ 3:0]  bonded;      //[3:0] - channel bonded with the other (just for channel 2), make it TIG
   
   input          restart_en;  // enable restarting selected channels
   input  [ 3:0]  restart;     // reinitialize channels (posedge-sensitive, masked by enXfer0
   output  [3:0]  nextBlocksEn; // enable read blocks to FIFO. disabled when init or roll over, enable by confirmRead

   reg    [3:0]   nextBlocksEn; // enable read blocks to FIFO. disabled when init or roll over, enable by confirmRead (always enabled for write channels)
   reg    [3:0]   channelIsRead=4'hf; // channel is programmed in read mode
   reg    [3:0]   bonded;      //[3:0] - channel bonded with the other (just for channel 2), make it TIG

   wire         chStOut;
   wire          enSDRAM;
   wire         enSDRAM0;
   reg          enRefresh;
   wire        enRefresh0;
   reg  [ 3:0]   enXfer;
   wire [ 3:0]   enXfer0;
   reg  [ 3:0]   steps; // one-hot states (2 SDclk each) - will switch MUXes
   reg  [ 3:0]   stepsEn;   // active during the second- enable registers
   assign      chStOut=stepsEn[2];
   reg         stepsI;   // 2 cycles after stepsInit
   reg         stepsIe;   // 1 cycle
   reg         stepsDwe;   // enable write to nBuf/tileY/tileX descriptor memory
   reg         stepsEn012;   // == |stepEn[2:0]
   reg  [ 1:0]   rNum;         // 2 LSBs of (internal) address of descriptor memory
   wire [ 2:0]   mancmdRqS;
   wire [17:0]   mancmd;
   reg  [ 1:0]   chInitNum;   // number of channel to request init
   reg         rqInit;
   reg         rqInitS;
   reg  [ 3:0]   chReqInit;
   reg         depend;
   reg            WnR;      // 0 - read from SDRAM, 1 - write to SDRAM
   reg            mode;      // 0 - 128x16bits, 1 - 16x8x16bits
   reg   [1:0]      nBuf;
   reg   [5:0]    seq_par;
   reg   [24:3]   sa;      // start SDRAM address
   reg   [24:8]   sfa; // start frame address - photofinish hack
   reg            rovr, pre_rovr;    // roll over mode (photofinish, cntrl0[12]==1


    reg   [ 9:0]   tileX;
    reg   [13:0]   tileY;
   reg            nxtTL;   // next tile line
   wire            nxtTLw;   // will be next tile line
   wire           last_line;     //valid @ Steps[2]
   wire           last_lines;     // valid @ Steps[2] Currnetly - 4 last (input) lines are too late to start compressing
                                  // improve - set a threshold (programmed/calculated)
   reg            last_lines_reg; //valid from Steps[3]
   reg            last_lines_source;
//   wire           first_line;     //valid @ Steps[2]
//   reg            first_line_reg; //valid from Steps[3]
//   reg            first_line_dest;
   wire           first_tile;     //valid @ Steps[2] - first (destinaltion) tile being processing - to prevent too late start
   reg            first_tile_reg; //valid from Steps[3]
   reg            first_tile_dest;
   wire           nxtTFw;   // will be next tile frame (will be used to generate channel done frame)
   reg            nxtTFr; // registered, same as |nextFrame[3:0]
   reg   [3:0]    nextFrame;
   reg            srcAtStart; // Source channel is ready fro the first data, but not started yet
   wire [17:0]   descr_stat; // internal output of 16x18 descriptor memory (ext - rw, int -ro)
   wire [21:0]   descr_dyn;   // internal output of 4x22 descriptor memory (nBuf/tileY/tileX)
   wire         rst=!enSDRAM;

// for binding of data source with data reciever
// save resources later by making source - always 0, dest - always 2??

   reg [13:0]   lineNumSource;
   reg [13:4]   prevStripSource; // number of source strip (line>>4) minus 1 - for faster comaprison w/o addition   
   reg [13:0]   lineNumDest;
   reg         destBond;   // desination channel bonded (should be set before writing to source channel)
   reg [ 1:0]   destChNum;   // channel number for data receiver
   reg [ 3:0]   suspXfer;   // block channel transfer till data source will provide data
   reg         setLineNumSource;
   reg         setLineNumDest;

   reg   [3:0] dest_bond_en;   // new fix
   reg         dest_mode;      // new fix


   wire         resetDestBond=   (chNum[1:0]==destChNum[1:0]);   //lower priority than set
//   wire         setDestBond=    descr_stat[13]&&!descr_stat[14];   // (depend, read) overwrites resetDestBond
   wire         setDestBond=    descr_stat[13]&&(!descr_stat[14] || descr_stat[15]);   // mode=1-> read! (depend, read) overwrites resetDestBond
   
   wire         setSourceBond=   descr_stat[13] && descr_stat[14] && !descr_stat[15];   // (depend, write, not mode1)
   wire         updSuspXfer;
   wire         notEnoughData;
///   wire        initChannelAsRead=!descr_stat[14] ;
   wire        initChannelAsRead=!descr_stat[14] || descr_stat[15] ; /// Was wrong for PF mode
   wire [17:0] mdo1;
   wire [21:0] mdo2;

   reg  [13:0] rnTilesY;
   reg         lastLineDest;
   wire [3:0]  chNumOneHot={chNum[1] & chNum[0],chNum[1] & ~chNum[0],~chNum[1] & chNum[0],~chNum[1] & ~chNum[0]};
   assign      notEnoughData= ((lineNumSource[13:4]==lineNumDest[13:4]) && // same 16-tile row
                               (dest_mode || (lineNumSource[3:0]==lineNumDest[3:0])) &&  // if destination is line-mode (never used)
                               (!srcAtStart || first_tile_dest ) ) || /// Just rolled over and image is just 32+4 pixels high
//                            (dest_mode && (lineNumSource[13:4]==(lineNumDest[13:4]+1'b1)) &&
                              (dest_mode && (prevStripSource[13:4]==lineNumDest[13:4]) &&
                               (lineNumSource[3:2]==2'b0)) || // additional 4 line for 20 lines
//                              (first_line_dest &&  last_lines_source) || // too late to start compression during last 4 input lines
                              (first_tile_dest &&  last_lines_source) || // too late to start compression during last 4 input lines
                              (lastLineDest && !(|lineNumSource[13:2]) && (dest_mode || !(|lineNumSource[1:0]) )); // roll over
//srcAtStart                                                            
   always @(negedge clk)
     if (stepsIe && setDestBond) dest_mode <= descr_stat[15];   // same as mode <=

   always @(negedge clk or posedge rst)
     if (rst) destBond <= 1'b0;
     else if (stepsIe) destBond <= setDestBond || (destBond && !resetDestBond);
   always @(negedge clk)
     if (stepsIe && setDestBond) destChNum[1:0] <= chNum[1:0]; 

   always @(negedge clk) begin
     setLineNumSource       <= steps[3] &&  WnR && depend && destBond && ~setLineNumSource;
     setLineNumDest          <= steps[3] && !WnR && depend && ~setLineNumDest;
   end

   always @(negedge clk) if (stepsIe) begin
     if (chNum[1:0]==2'b00) begin
        dest_bond_en[0]  <= setDestBond;
        channelIsRead[0] <= initChannelAsRead;
     end
     if (chNum[1:0]==2'b01) begin
        dest_bond_en[1] <= setDestBond;
        channelIsRead[1] <= initChannelAsRead;
     end
     if (chNum[1:0]==2'b10) begin
        dest_bond_en[2] <= setDestBond;
        channelIsRead[2] <= initChannelAsRead;
     end
     if (chNum[1:0]==2'b11) begin
        dest_bond_en[3] <= setDestBond;
        channelIsRead[3] <= initChannelAsRead;
     end
   end
   always @(negedge clk) bonded[3:0] <= dest_bond_en[3:0];      //[3:0] - channel bonded with the other (just for channel 2), make it TIG
//    reg           nxtTL_r;
    reg     [2:0] nxtTF_p;
    wire          nxtTf_d= &nxtTF_p; // valid @ stepsEn[3]
   always @ (negedge clk) begin
    nextBlocksEn[3:0] <= ~channelIsRead[3:0] |  //always enabled for write channels
                          confirmRead[3:0]   |  // confirmed read, may continue (level "1" if not needed)
                         (nextBlocksEn[3:0] & 
                          ~({4{stepsIe}}    & chNumOneHot[3:0] )  &  // turn off after programming (write mode is excluded above)
                          ~({4{stepsEn[3] & nxtTf_d} } & chNumOneHot[3:0])); // turn off at next frame
   end

   always @(negedge clk) begin
     if (stepsIe && setSourceBond) lineNumSource[13:0] <= 14'h0;
     else if (setLineNumSource)    lineNumSource[13:0] <= {tileY[13:4],mode?4'b0:tileY[3:0]};

     if (stepsIe && setSourceBond) srcAtStart<=1'b1;   // just initialized
     else   if (setLineNumSource)  srcAtStart<=nxtTFr; // just rolled over

  
//   reg            srcAtStart; // Source channel is ready fro the first data, but not started yet
  
     prevStripSource[13:4] <= lineNumSource[13:4]-1;

     if (stepsIe && setDestBond) lineNumDest[13:0]     <= 14'h0;
     else if (setLineNumDest)    lineNumDest[13:0]     <= {tileY[13:4],mode?4'b0:tileY[3:0]};

     if (stepsIe && setDestBond) lastLineDest <= 1'b0;
     else if (setLineNumDest)
           lastLineDest <= pre_rovr && (tileY[13:4]==rnTilesY[13:4]) && (mode || (tileY[3:0]==rnTilesY[3:0]));

     if (stepsIe && setSourceBond) last_lines_source <= 1'b0;
     else if (setLineNumSource)    last_lines_source <= last_lines_reg;

//     if (stepsIe && setDestBond)   first_line_dest <= 1'b1;
//     else if (setLineNumDest)      first_line_dest <= first_line_reg;

     if (stepsIe && setDestBond)   first_tile_dest <= 1'b1;
     else if (setLineNumDest)      first_tile_dest <= first_tile_reg;
   end

reg        restart_en_sync;
reg  [3:0] enRestart; 
wire [3:0] extRestartRq0;
reg  [3:0] extRestartRq1;
reg  [3:0] extRestartRq2;
reg  [3:0] extRestartRq;
   always @(negedge clk) begin
     restart_en_sync <= restart_en;
     enRestart[3:0] <= enXfer0[3:0] & {4{restart_en_sync}};
     extRestartRq1[3:0] <= extRestartRq0[3:0];
     extRestartRq2[3:0] <= extRestartRq1[3:0];
     extRestartRq[3:0]  <= extRestartRq1[3:0] & (~extRestartRq2[3:0]);
   end
   FDCE   i_extRestartRq0_0 (.C(restart[0]),.CLR(!enRestart[0] || extRestartRq[0] ),.CE(1'b1),.D(enRestart[0]),.Q(extRestartRq0[0]));
   FDCE   i_extRestartRq0_1 (.C(restart[1]),.CLR(!enRestart[1] || extRestartRq[1] ),.CE(1'b1),.D(enRestart[1]),.Q(extRestartRq0[1]));
   FDCE   i_extRestartRq0_2 (.C(restart[2]),.CLR(!enRestart[2] || extRestartRq[2] ),.CE(1'b1),.D(enRestart[2]),.Q(extRestartRq0[2]));
   FDCE   i_extRestartRq0_3 (.C(restart[3]),.CLR(!enRestart[3] || extRestartRq[3] ),.CE(1'b1),.D(enRestart[3]),.Q(extRestartRq0[3]));


/*
   input          restart_en;  // enable restarting seslcted channels
   input  [ 3:0]  restart;     // reinitialize channles (posedge-sensitive, masked by enXfer0
//   FDCE   i_mancmdRq (.C(wclk),.CLR(mancmdRqS[1]),.CE(mcs),.D(mancmdRq | (maddr[3:0] == 4'h3)),.Q(mancmdRq));

*/



//   MSRL16_1 i_updSuspXfer (.Q(updSuspXfer), .A(4'h1), .CLK(clk), .D(setLineNumSource || setLineNumDest));// dly=1+1
// after registering prevStripSource need 2 more cycles. Should not break anything if the suspXfer signal
// is delayed by 2 clock cycles - all decisions are already made (some 10-20 cycles earlier)
   MSRL16_1 i_updSuspXfer (.Q(updSuspXfer), .A(4'h3), .CLK(clk), .D(setLineNumSource || setLineNumDest));// dly=1+3

//suspXfer (all 4) will at stepsIe will be set/reset to setDestBond (only selected, others - reset)
//suspXfer (selected) will be updated both at write to source and read from dest
   always @(negedge clk)
     if (stepsIe && setDestBond) suspXfer[0] <= (chNum[1:0]==2'b00);
     else if (updSuspXfer && (destChNum[1:0]==2'b00)) suspXfer[0] <= notEnoughData;
   always @(negedge clk)
     if (stepsIe && setDestBond) suspXfer[1] <= (chNum[1:0]==2'b01);
     else if (updSuspXfer && (destChNum[1:0]==2'b01)) suspXfer[1] <= notEnoughData;
   always @(negedge clk)
     if (stepsIe && setDestBond) suspXfer[2] <= (chNum[1:0]==2'b10);
     else if (updSuspXfer && (destChNum[1:0]==2'b10)) suspXfer[2] <= notEnoughData;
   always @(negedge clk)
     if (stepsIe && setDestBond) suspXfer[3] <= (chNum[1:0]==2'b11);
     else if (updSuspXfer && (destChNum[1:0]==2'b11)) suspXfer[3] <= notEnoughData;


// refresh and SDRAM automatic access control
//   always @ (posedge wclk) if (mcs && (maddr[3:0]==4'h7)) {enXfer0[3:0],enRefresh0} <= mdi[5:1];
// use to initialize by glbl.GSR = 1'b1;

// simplify here?
//   always @ (negedge clk) if (mcs && (as[3:0]==4'h7)) {enXfer0[3:0],enRefresh0} <= mdi[5:1];
//   FDE_1   i_enSDRAM0 (.C(clk),.CE(mcs && (as[3:0]==4'h7)),.D(mdi[0]),.Q(enSDRAM0));

/// Modified to enable selective set/reset bits, without changing others
   FDE_1   i_enSDRAM0   (.C(clk),.CE(mcs && (as[3:0]==4'h7) && mdi[ 1]),.D(mdi[ 0]),.Q(enSDRAM0));
   FDE_1   i_enRefresh0 (.C(clk),.CE(mcs && (as[3:0]==4'h7) && mdi[ 3]),.D(mdi[ 2]),.Q(enRefresh0));
   FDE_1   i_enXfer00   (.C(clk),.CE(mcs && (as[3:0]==4'h7) && mdi[ 5]),.D(mdi[ 4]),.Q(enXfer0[0]));
   FDE_1   i_enXfer01   (.C(clk),.CE(mcs && (as[3:0]==4'h7) && mdi[ 7]),.D(mdi[ 6]),.Q(enXfer0[1]));
   FDE_1   i_enXfer02   (.C(clk),.CE(mcs && (as[3:0]==4'h7) && mdi[ 9]),.D(mdi[ 8]),.Q(enXfer0[2]));
   FDE_1   i_enXfer03   (.C(clk),.CE(mcs && (as[3:0]==4'h7) && mdi[11]),.D(mdi[10]),.Q(enXfer0[3]));

// always @ (negedge clk) {enXfer[3:0],enRefresh} <= {(enXfer0[3:0] & ~(suspXfer[3:0] & dest_bond_en[3:0])),enRefresh0};   // synchronize
   always @ (negedge clk) {enXfer[3:0],enRefresh} <= {(enXfer0[3:0] & nextBlocksEn[3:0] & ~(suspXfer[3:0] & dest_bond_en[3:0])),enRefresh0};   // synchronize
   FD_1      i_enSDRAM  (.C(clk),.D(enSDRAM0),.Q(enSDRAM));


//   FDCE   i_mancmdRq (.C(wclk),.CLR(mancmdRqS[1]),.CE(mcs),.D(mancmdRq | (maddr[3:0] == 4'h3)),.Q(mancmdRq));
   FD_1   i_mancmdRqS_0  (.C(clk),.D((mcs && (as[3:0] == 4'h3)) || (mancmdRqS[0] && !mancmdRqS[1]) ),.Q(mancmdRqS[0]));
   FD_1   i_mancmdRqS_1  (.C(clk),.D(mancmdRqS[0]),.Q(mancmdRqS[1]));
   FD_1   i_mancmdRqS_2  (.C(clk),.D(mancmdRqS[0] && mancmdRqS[1]),.Q(mancmdRqS[2]));

// generate address - will be 0 for init
   always @ (negedge clk) rNum[1:0] <= {mancmdRqS[0] || stepsEn[1] || (steps[2] && !stepsEn[2]),
                                        mancmdRqS[0] || stepsEn[0] || (steps[1] && !stepsEn[1])};
   FD_1 #(.INIT(1'b1)) i_mancmd_00  (.C(clk),.D(!mancmdRqS[2] | descr_stat[ 0]),.Q(mancmd[ 0]));
   FD_1 #(.INIT(1'b1)) i_mancmd_01  (.C(clk),.D(!mancmdRqS[2] | descr_stat[ 1]),.Q(mancmd[ 1]));
   FD_1 #(.INIT(1'b1)) i_mancmd_02  (.C(clk),.D(!mancmdRqS[2] | descr_stat[ 2]),.Q(mancmd[ 2]));
   FD_1 #(.INIT(1'b1)) i_mancmd_03  (.C(clk),.D(!mancmdRqS[2] | descr_stat[ 3]),.Q(mancmd[ 3]));
   FD_1 #(.INIT(1'b1)) i_mancmd_04  (.C(clk),.D(!mancmdRqS[2] | descr_stat[ 4]),.Q(mancmd[ 4]));
   FD_1 #(.INIT(1'b1)) i_mancmd_05  (.C(clk),.D(!mancmdRqS[2] | descr_stat[ 5]),.Q(mancmd[ 5]));
   FD_1 #(.INIT(1'b1)) i_mancmd_06  (.C(clk),.D(!mancmdRqS[2] | descr_stat[ 6]),.Q(mancmd[ 6]));
   FD_1 #(.INIT(1'b1)) i_mancmd_07  (.C(clk),.D(!mancmdRqS[2] | descr_stat[ 7]),.Q(mancmd[ 7]));
   FD_1 #(.INIT(1'b1)) i_mancmd_08  (.C(clk),.D(!mancmdRqS[2] | descr_stat[ 8]),.Q(mancmd[ 8]));
   FD_1 #(.INIT(1'b1)) i_mancmd_09  (.C(clk),.D(!mancmdRqS[2] | descr_stat[ 9]),.Q(mancmd[ 9]));
   FD_1 #(.INIT(1'b1)) i_mancmd_10  (.C(clk),.D(!mancmdRqS[2] | descr_stat[10]),.Q(mancmd[10]));
   FD_1 #(.INIT(1'b1)) i_mancmd_11  (.C(clk),.D(!mancmdRqS[2] | descr_stat[11]),.Q(mancmd[11]));
   FD_1 #(.INIT(1'b1)) i_mancmd_12  (.C(clk),.D(!mancmdRqS[2] | descr_stat[12]),.Q(mancmd[12]));
   FD_1 #(.INIT(1'b1)) i_mancmd_13  (.C(clk),.D(!mancmdRqS[2] | descr_stat[13]),.Q(mancmd[13]));
   FD_1 #(.INIT(1'b1)) i_mancmd_14  (.C(clk),.D(!mancmdRqS[2] | descr_stat[14]),.Q(mancmd[14]));
   FD_1 #(.INIT(1'b1)) i_mancmd_15  (.C(clk),.D(!mancmdRqS[2] | descr_stat[15]),.Q(mancmd[15]));
   FD_1 #(.INIT(1'b1)) i_mancmd_16  (.C(clk),.D(!mancmdRqS[2] | descr_stat[16]),.Q(mancmd[16]));
   FD_1 #(.INIT(1'b1)) i_mancmd_17  (.C(clk),.D(!mancmdRqS[2] | descr_stat[17]),.Q(mancmd[17]));


   always @ (negedge clk) if (mcs && (as[1:0] == 2'h0)) chInitNum[1:0] <= as[3:2];

   always @ (negedge clk) begin
     rqInit  <= mcs && (as[1:0] == 2'h0);
     rqInitS <= rqInit;
     chReqInit <= extRestartRq[3:0] | {rqInitS && (chInitNum[1:0]==2'b11),
                                       rqInitS && (chInitNum[1:0]==2'b10),
                                       rqInitS && (chInitNum[1:0]==2'b01),
                                       rqInitS && (chInitNum[1:0]==2'b00)};
   end
   

// sequence of address calculation
// adding reset (simulation only)?
    always @ (negedge clk or posedge rst)
    if (rst) begin
       steps[3:0]   <= 4'b0;
       stepsI       <= 1'b0;
    end else begin
       steps[3:0]   <= {stepsEn[2:0],(chStIn & !chInit)} | (steps[3:0] &~stepsEn[3:0]);
       stepsI       <= chInit || (stepsI && ~stepsIe);
    end
    always @ (negedge clk) begin
      stepsEn[3:0] <= (steps[3:0] & ~stepsEn[3:0]);
       stepsEn012    <= |steps[2:0] && ~(|stepsEn[2:0]);
      stepsIe       <= stepsI && ~stepsIe;
      stepsDwe       <= (stepsI || steps[3]) && ~stepsDwe;
    end

// to fit 18-bit memory, 2 bits are overlapped:
//   assign mdo[31:0]={mdo2[19:4],(ia[1:0]==2'b10)?mdo2mdo2[3:0]:mdo1[17:12],mdo1[11:0]};
// read actual SDRAM enable register (masked in bits 11:6, unmasked (as written) in bits 5:0
   assign mdo[31:0]={mdo2[21:20], //nBuf[1:0]
   (ia[1:0]==2'h2)?
      mdo2[13:0]:  //some tileY, all tileX
      mdo2[19:6],  // all tile Y (in mode 1 - some tile X also)
   (ia[3:0]==4'h7)?
//      {4'h0,enXfer[3:0],enRefresh,enSDRAM,enXfer0[3:0],enRefresh0,enSDRAM0}:
      {nextBlocksEn[3:0],enXfer[3:0],enRefresh,enSDRAM,enXfer0[3:0],enRefresh0,enSDRAM0}:
      mdo1[15:0]}; ///mdo1[17:16] are not read back - these bits are used only in mancmd


myRAM_WxD_D #( .DATA_WIDTH(18),.DATA_DEPTH(4))
            i_descr_stat(.D(mdi[17:0]),
                        .WE(mcs),
                        .clk(~clk),
                        .AW(am[3:0]),
                        .AR({chNum[1:0],rNum[1:0]}),
                        .QW(mdo1[17:0]), ///NOTE:  2 MSBs not used
                        .QR(descr_stat[17:0]));

// nBuf[1:0] will start with 2'b00 (after first read from memory)

myRAM_WxD_D #( .DATA_WIDTH(22),.DATA_DEPTH(2))
            i_descr_dyn(.D(stepsI?22'h300000:{nBuf[1:0],tileY[13:4],(mode?tileX[9:5]:{tileY[3:0],1'b0}),tileX[4:0]}),
                        .WE(stepsDwe),
                        .clk(~clk),
                        .AW(chNum[1:0]),
                        .AR(ia[3:2]),
                        .QW(descr_dyn[21:0]),
                        .QR(mdo2[21:0]));


    assign         nxtTLw=     mode?(descr_dyn[9:0]==descr_stat[13:4]):(descr_dyn[4:0]==descr_stat[13:9]); // step[1]
    assign         last_line=  (descr_dyn[19:10]==descr_stat[13:4]) && (mode || (descr_dyn[9:6]==descr_stat[3:0]));   // step[2]
    assign         last_lines= (descr_dyn[19:10]==descr_stat[13:4]) && (mode || (descr_dyn[9:8]==descr_stat[3:2]));   // step[2]
//    assign         first_line= (descr_dyn[19:10]==10'h0) && (mode || (descr_dyn[9:6]==4'h0));   // step[2]
    assign         first_tile= (descr_dyn[19:0]==20'h0);   // step[2]
    assign         nxtTFw=     nxtTL && last_line;   // step[2]


    always @ (negedge clk) if (stepsEn[0] || stepsIe) begin      // address should be 0
      mode   <=descr_stat[15];      // address should be 0
      WnR   <= descr_stat[14] && !descr_stat[15];      // address should be 0 (mask WnR by mode, use descr_stat[15:14]==2'b11 as PF-mode
      pre_rovr  <= descr_stat[14] && descr_stat[15] ; //
      depend<= descr_stat[13];
//      pre_rovr  <= descr_stat[12];    // roll over mode (photofinish, cntrl0[12]==1 /// NOTE:Does it need to be fixed??

    end

   always @ (negedge clk) if (stepsEn[2]) rovr          <= last_line && pre_rovr; //last_line valid at stepsEn[2] only
   
//TODO: set first/last at channel init   
   always @ (negedge clk) if (stepsEn[2]) last_lines_reg <= last_lines ; //last_lines valid at stepsEn[2] only
//   always @ (negedge clk) if (stepsEn[2]) first_line_reg <= first_line ; //first_line valid at stepsEn[2] only
   always @ (negedge clk) if (stepsEn[2]) first_tile_reg <= first_tile ; //first_line valid at stepsEn[2] only

    always @ (negedge clk) if (stepsEn[0]) begin      // address should be 0
      nBuf[1:0]   <=descr_dyn[21:20]+1; 
    end
    
   wire [4:0] padlen;
   assign padlen=((mode && (descr_stat[8:4]==5'h1f))?(descr_stat[13:9]+1'b1):descr_stat[13:9])+1;

   reg   [15:0]   linAddr;
//   wire  [15:0]   linAddr;      //replacing with latches to ease timing
   wire  [15:0]   linAddr_input;
   wire [4:0] descr_stat_inc=descr_stat[8:4]+1;    
   assign linAddr_input[15:0] = padlen[4:0]*{descr_dyn[19:10],mode?4'b0:descr_dyn[9:6]};

    
    always @ (negedge clk) if (stepsEn[1]) begin      // address should be 1
//memctrl353/descrproc353.v:504: error: Concatenation operand "((descr_dyn['sd4:'sd0])==(descr_stat['sd13:'sd9]))?((descr_stat['sd8:'sd4])+('sd1)):(5'd0)" has indefinite width.    
//      seq_par[5:0] <= mode?({1'b0,descr_stat[13:9]}+((descr_stat[8:4]==5'h1f)?2'h2:2'h1)): //fixed bug with pages where number of hor. tiles is multiple of 0x10
//                           ({1'b0,(descr_dyn[4:0]==descr_stat[13:9])?(descr_stat[8:4]+1):5'b0});
      seq_par[5:0] <= mode?({1'b0,descr_stat[13:9]}+((descr_stat[8:4]==5'h1f)?2'h2:2'h1)): //fixed bug with pages where number of hor. tiles is multiple of 0x10
                           ({1'b0,(descr_dyn[4:0]==descr_stat[13:9])?(descr_stat_inc):5'b0});
      sa[7:3] <= mode?descr_dyn[4:0]:5'b0;
      linAddr[15:0]   <= linAddr_input[15:0];
      nxtTL <= nxtTLw;
      tileX[ 9:0] <= nxtTLw?  10'b0 : (descr_dyn[9:0]+1);   // bits [9:5] are garbage if (mode==0)

    end
/*    
 reg     linAddr_en;
  always @ (negedge clk) linAddr_en <= (stepsEn[1]);
 LDCPE i_linAddr_0  (.Q(linAddr[ 0]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_1  (.Q(linAddr[ 1]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_2  (.Q(linAddr[ 2]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_3  (.Q(linAddr[ 3]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_4  (.Q(linAddr[ 4]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_5  (.Q(linAddr[ 5]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_6  (.Q(linAddr[ 6]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_7  (.Q(linAddr[ 7]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_8  (.Q(linAddr[ 8]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_9  (.Q(linAddr[ 9]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_10 (.Q(linAddr[10]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_11 (.Q(linAddr[11]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_12 (.Q(linAddr[12]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_13 (.Q(linAddr[13]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_14 (.Q(linAddr[14]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
 LDCPE i_linAddr_15 (.Q(linAddr[15]), .D(linAddr_input[ 0]), .G(clk), .GE(linAddr_en), .CLR(1'b0),.PRE(1'b0));
*/  
/*
   wire  [15:0]   linAddr;      //replacing with latches to ease timing
   wire  [15:0]   linAddr_input;

   LDCPE #(
      .INIT(1'b0) // Initial value of latch (1'b0 or 1'b1)
   ) LDCPE_inst (
      .Q(Q),      // Data output
      .CLR(CLR),  // Asynchronous clear/reset input
      .D(D),      // Data input
      .G(G),      // Gate input
      .GE(GE),    // Gate enable input
      .PRE(PRE)   // Asynchronous preset/set input
   );

*/
    always @ (negedge clk) if (stepsEn[2]) begin      // address should be 2
      tileY[13:0] <= nxtTFw? 14'b0 :  (descr_dyn[19:6]+{9'b0,(nxtTL  && mode),3'b0,(nxtTL  && !mode)});
      rnTilesY[13:0] <= descr_stat[13:0];

      nxtTF_p[2:0] <={nxtTL, (descr_dyn[19:10]==descr_stat[13:4])?1'b1:1'b0, (mode || (descr_dyn[9:6]==descr_stat[3:0]))?1'b1:1'b0};


    end
    always @ (negedge clk) if (stepsEn012) begin
      sa[24:8] <= steps[0]?
        {4'b0,descr_stat[12:0]}:
        (sa[24:8]+
             (steps[1]?
                  {descr_stat[3:0],8'b0,mode?
                       descr_dyn[9:5]:
                       descr_dyn[4:0]}:
                  {linAddr[15:0]}));
    end
 //photofinish hack
    always @ (negedge clk) if (stepsEn[1]) begin
      sfa[24:8] <= {descr_stat[3:0], sa[20:8]};
    end

    always @ (negedge clk) begin
      if (stepsEn[2] && (chNum[1:0]==2'b00)) nextFrame[0] <= nxtTFw;
      if (stepsEn[2] && (chNum[1:0]==2'b01)) nextFrame[1] <= nxtTFw;
      if (stepsEn[2] && (chNum[1:0]==2'b10)) nextFrame[2] <= nxtTFw;
      if (stepsEn[2] && (chNum[1:0]==2'b11)) nextFrame[3] <= nxtTFw;
      if (stepsEn[2] )                       nxtTFr       <= nxtTFw;
    end
    

endmodule

