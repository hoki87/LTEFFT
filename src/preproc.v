/////////////////////////// INCLUDE /////////////////////////////
`include "../../src/lte_fft_inc.v"

////////////////////////////////////////////////////////////////
//
//  Module  : preproc
//  Designer: Hoki
//  Company : HWorks
//  Date    : 2016/6/8 14:47:25
//
////////////////////////////////////////////////////////////////
// 
//  Description: precondition for FFT and IFFT
//               - FFT:  remove CP
//               - IFFT: pass through
//
////////////////////////////////////////////////////////////////
// 
//  Revision: 1.0

module preproc
(
   clk          ,
   reset        ,
   fft_type     ,
   cp_type      ,
   fft_num      ,
   din_i        ,
   din_q        ,
   din_h        ,
   din_s        ,
   din_v        ,
`ifdef ALTERA   
   dout_sop     ,
   dout_valid   ,
   dout_real    ,
   dout_imag    ,
   dout_eop     ,
`else
   din_rfd      ,
   dout_start   ,
   dout_nfft_we ,
   dout_nfft    ,
   dout_inv_we  ,
   dout_inv     ,
   dout_scale_we,
   dout_scale   ,
   dout_xn_re   ,
   dout_xn_im   ,
`endif
   dout_fst_cp
);

   ///////////////// PARAMETER ////////////////
   parameter DATA_NBIT    = 15;
   
   ////////////////// PORT ////////////////////
   input                       clk;           // clock input                       
   input                       reset;         // reset input
   input                       fft_type;      // 0: FFT, 1 - IFFT
   input                       cp_type;       // 0 - normal, 1 - extended 
   input  [2:0]                fft_num;       // 0 - 2048,1 - 1024,3 - 512,4 - 256, 5 - 128
   input  [DATA_NBIT-1:0]      din_i;         // I path data input                 
   input  [DATA_NBIT-1:0]      din_q;         // Q path data input                 
   input                       din_h;         // first sample data valid input
   input                       din_s;         // first time slot valid input  
   input                       din_v;         // sample data valid input      
`ifdef ALTERA                                 
   output                      dout_sop;      // start of packet
   output                      dout_valid;    // data valid output
   output [DATA_NBIT-1:0]      dout_real;     // I path data output     
   output [DATA_NBIT-1:0]      dout_imag;     // Q path data output    
   output                      dout_eop;      // end of packet 
`else
   input                       din_rfd;       // ready for data input
   output                      dout_start;    // start output
   output                      dout_nfft_we;  // FFT/IFFT number write output
   output [`FFT_NFFT_NBIT-1:0] dout_nfft;     // FFT/IFFT number output
   output                      dout_inv_we;   // inverse write output
   output                      dout_inv;      // inverse output
   output                      dout_scale_we; // scale schedule write output
   output [`FFT_SCH_NBIT-1:0]  dout_scale;    // scale schedule output
   output [DATA_NBIT-1:0]      dout_xn_re;    // real data output
   output [DATA_NBIT-1:0]      dout_xn_im;    // imag data output
`endif
   output                      dout_fst_cp;   // the flag of first cp
   
   ////////////////// ARCH ////////////////////
   reg                         cache_fst_cp  ; // latch fst_cp   for following modules
   reg  [`FFT_NUM_NBIT-1:0]    cache_fft_num;
   reg  [`FFT_NUM_NBIT-1:0]    cache_cp_num;
   reg                         cache_switch;  // ping pang ram switch                     
   reg  [`FFT_NUM_NBIT-1:0]    cache_waddr;
   reg                         buf_wr_en;
   wire                        buf_wr;
   wire [`BUF_ADDR_NBIT:0]     buf_waddr;
   wire [DATA_NBIT*2-1:0]      buf_wdata; // {data_i,data_q}
  
   assign buf_wr    = din_v&buf_wr_en;
   assign buf_waddr = {cache_switch,cache_waddr[`BUF_ADDR_NBIT-1:0]};
   assign buf_wdata = {din_i,din_q};
   
   always@(posedge clk) begin
      if(reset) begin
         cache_fst_cp  <= `LOW;
         cache_fft_num <= `FFT_NUM_NBIT'd`FFT_MAX_NUM;
         cache_cp_num  <= `FFT_NUM_NBIT'd`CP_NOR_NUM;
         cache_switch  <= `LOW;
         cache_waddr   <= 0;
         buf_wr_en     <= `LOW;
      end
      else begin
         if(din_v) begin
            cache_waddr <= cache_waddr + 1'b1;
            if(~buf_wr_en) begin // remove CP
               if(cache_waddr==cache_cp_num-1) begin
                  buf_wr_en   <= `HIGH;
                  cache_waddr <= 0;
               end
            end
            else begin // pass valid data
               if(cache_waddr==cache_fft_num-1) begin
                  buf_wr_en    <= `LOW;
                  cache_waddr  <= 0;
                  cache_switch <= ~cache_switch; // switch ram bank after cache all data
               end
            end
         end
         
         // latch FFT number and CP number
         if(din_h) begin
            cache_fft_num <= `FFT_NUM_NBIT'd`FFT_MAX_NUM>>fft_num;
            if(cp_type)
               cache_cp_num  <= `FFT_NUM_NBIT'd`CP_EXT_NUM>>fft_num;
            else begin
               if(din_s)
                  cache_cp_num <= `FFT_NUM_NBIT'd`CP_NOR_FST_NUM>>fft_num;
               else
                  cache_cp_num <= `FFT_NUM_NBIT'd`CP_NOR_NUM>>fft_num;
            end
            cache_fst_cp   <= din_s;
            cache_waddr    <= 0;
            if(din_v)
               cache_waddr <= `FFT_NUM_NBIT'd1;
            buf_wr_en      <= fft_type;
         end
      end
   end

   ////////////////// PING PANG RAM
`ifdef ALTERA
   (*ramstyle="M10K"*)  reg [DATA_NBIT*2-1:0]  BUFFER[0:2**(`BUF_ADDR_NBIT+1)-1];
`else
   (*RAM_STYLE="BLOCK"*)reg [DATA_NBIT*2-1:0]  BUFFER[0:2**(`BUF_ADDR_NBIT+1)-1];
`endif
   
   // simple dual port RAM
   wire [`BUF_ADDR_NBIT:0]  buf_raddr;
   reg  [DATA_NBIT*2-1:0]   buf_rdata; // {data_i,data_q}
   always@(posedge clk) begin
      if(buf_wr)
         BUFFER[buf_waddr] <= buf_wdata;
      buf_rdata <= BUFFER[buf_raddr]; // read-during-write, old data
   end
   
   ////////////////// DOUT
   reg                      dout_fst_cp  ;
   reg  [`FFT_NUM_NBIT-1:0] cache_raddr={`FFT_NUM_NBIT{1'b1}};
   reg                      prev_cache_switch;
   
   assign buf_raddr = {~cache_switch,cache_raddr[`BUF_ADDR_NBIT-1:0]};
   
   always@(posedge clk) begin   
      if(reset) begin
         dout_fst_cp       <= `LOW;
         cache_raddr       <= {`FFT_NUM_NBIT{1'b1}};
         prev_cache_switch <= `LOW;
      end
      else begin
         prev_cache_switch <= cache_switch;
         if(cache_switch^prev_cache_switch)  // reset address when sop
            cache_raddr <= 0;
         else if(cache_raddr<cache_fft_num) // address range: 0 ~ cache_fft_num
            cache_raddr <= cache_raddr + 1'b1;
         
         if(fft_type) begin // IFFT: pass through
            if(din_h) begin
               dout_fst_cp   <= din_s;
            end
         end
         else begin         // FFT: remove cp
            if(din_v&&(cache_waddr==cache_fft_num-1)) begin
               dout_fst_cp   <= cache_fst_cp  ;
            end
         end
      end
   end

`ifdef ALTERA
   // ALTERA FFT IP Core Interface
   reg                      buf_rd;
   reg                      dout_sop  ;  
   reg                      dout_valid;
   reg  [DATA_NBIT-1:0]     dout_real ;
   reg  [DATA_NBIT-1:0]     dout_imag ;
   reg                      dout_eop  ;

   always@(posedge clk) begin   
      if(reset) begin
         buf_rd      <= `LOW;
         dout_sop    <= `LOW;
         dout_real   <= 0;
         dout_imag   <= 0;
         dout_valid  <= `LOW;
         dout_eop    <= `LOW;
      end
      else begin
         buf_rd <= `LOW;
         if(cache_raddr<cache_fft_num) // valid when address range 0 ~ cache_fft_num-1
            buf_rd <= `HIGH;
            
         if(fft_type) begin // IFFT: pass through
            dout_sop   <= buf_wr_en&din_v&~dout_valid;
            dout_real  <= din_i;
            dout_imag  <= din_q;
            dout_valid <= din_v;
            dout_eop   <= buf_wr_en&(cache_waddr==cache_fft_num-1);
         end
         else begin         // FFT: remove cp
            dout_sop   <= buf_rd&(cache_raddr==1);
            dout_valid <= buf_rd;
            dout_real  <= buf_rdata[DATA_NBIT*2-1:DATA_NBIT];
            dout_imag  <= buf_rdata[DATA_NBIT-1:0];
            dout_eop   <= buf_rd&(cache_raddr==cache_fft_num);
         end
      end
   end
`else
   // XILINX FFT/IFFT IP Core Interface
   reg                      dout_start;    // start output
   reg                      dout_nfft_we;  // FFT/IFFT number write output
   reg [`FFT_NFFT_NBIT-1:0] dout_nfft;     // FFT/IFFT number output
   reg                      dout_inv_we;   // inverse write output
   reg                      dout_inv;      // inverse output
   reg                      dout_scale_we; // scale schedule write output
   reg [`FFT_SCH_NBIT-1:0]  dout_scale;    // scale schedule output
   reg [DATA_NBIT-1:0]      dout_xn_re;    // real data output
   reg [DATA_NBIT-1:0]      dout_xn_im;    // imag data output
   reg                      p_cache_switch;
   
   always@* begin
      if(reset) begin
         dout_nfft_we  <= `LOW;
         dout_nfft     <= `FFT_NFFT_2048;
         dout_inv_we   <= `LOW;
         dout_inv      <= `LOW;
         dout_scale_we <= `LOW;
         dout_scale    <= 0;
      end
      else begin
         dout_nfft    <= `FFT_NFFT_2048-fft_num; // 2048 - b01011, 1024 - b01010, 512 - b01001, 256 - b01000, 128 - b00111
         dout_inv     <= ~fft_type;
         // shift log2(fft_num)+2 bits
         case(fft_num)
            3'd0:    dout_scale <= `FFT_SCH_NBIT'b10_10_10_11_10_01; // 12 bits, shift 12
            3'd1:    dout_scale <= `FFT_SCH_NBIT'b00_10_10_11_10_10; // 10 bits, shift 11
            3'd2:    dout_scale <= `FFT_SCH_NBIT'b00_10_10_11_10_01; // 10 bits, shift 10
            3'd3:    dout_scale <= `FFT_SCH_NBIT'b00_00_10_11_10_10; // 8  bits, shift 9
            3'd4:    dout_scale <= `FFT_SCH_NBIT'b00_00_10_11_10_01; // 8  bits, shift 8
            default: dout_scale <= `FFT_SCH_NBIT'b10_10_10_11_10_01;
         endcase 
         if(fft_type) begin // IFFT: pass through
            dout_nfft_we <= din_h;
            dout_inv_we  <= din_h;
            dout_scale_we<= din_h;
         end
         else begin        // FFT: remove CP
            dout_nfft_we <= cache_switch^prev_cache_switch;
            dout_inv_we  <= cache_switch^prev_cache_switch;
            dout_scale_we<= cache_switch^prev_cache_switch;
         end
      end
   end
   
   always@(posedge clk) begin
      if(reset) begin
         dout_start     <= `LOW;
         dout_xn_re     <= 0;
         dout_xn_im     <= 0;  
         p_cache_switch <= `LOW;
      end
      else begin
         p_cache_switch <= cache_switch^prev_cache_switch;    
         if(fft_type) begin // IFFT: pass through
            dout_start  <= din_h;
            dout_xn_re  <= din_i;
            dout_xn_im  <= din_q;
         end
         else begin        // FFT: remove cp
            dout_start  <= p_cache_switch;
            dout_xn_re  <= buf_rdata[DATA_NBIT*2-1:DATA_NBIT];
            dout_xn_im  <= buf_rdata[DATA_NBIT-1:0];         
         end
      end
   end
`endif

endmodule