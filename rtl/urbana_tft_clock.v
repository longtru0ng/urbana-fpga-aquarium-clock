`timescale 1ns / 1ps
// RealDigital Urbana XC7S50 + ILI9341 SPI 320x240 landscape.
// Aquarium V10.5: V10.4 art, movement state, merged dirty rectangles and low-rate vegetation refresh.
// - more stylized HH:MM clock font (no seconds)
// - rotary changes HOUR / MIN / COLOR / BACKGROUND
// - grass uses independently swaying, low-amplitude curves and checks neighboring root cells
// - plain background is restored under animated grass (no clipping borders)
// - isolated floating bubbles, without satellite bubbles / trails
// - fish + puffer fish + better seahorse + shark + octopus + jellyfish + tiny fish school
module urbana_tft_clock #(
    parameter integer SPI_HALF_DIV = 5,       // 10 MHz from 100 MHz system clock
    parameter integer FRAME_CYCLES = 2500000  // 40 motion ticks/sec target
)(
    input  wire CLK_100MHZ,
    input  wire enc_a,
    input  wire enc_b,
    input  wire enc_sw,
    input  wire enc_swt,
    output reg  tft_cs  = 1'b1,
    output reg  tft_dc  = 1'b1,
    output reg  tft_rst = 1'b0,
    output wire tft_sck,
    output wire tft_mosi
);
    localparam [2:0] MODE_RUN=0, MODE_HOUR=1, MODE_MIN=2,
                     MODE_COLOR=3, MODE_SCENE=4;

    localparam [4:0] R_FULL=0, R_DIGITS=1, R_STATUS=2,
                     R_FISH_FIRST=3, R_FISH_LAST=11,
                     R_BUBBLE_FIRST=12, R_BUBBLE_LAST=19,
                     R_GRASS=20;

    localparam [3:0] ST_RST_LO=0, ST_RST_HI=1, ST_INIT=2,
                     ST_PAUSE=3, ST_IDLE=4, ST_WINDOW=5,
                     ST_PIXEL=6, ST_SEND=7, ST_WAIT=8, ST_REEF_FETCH=9, ST_SPRITE_READ=10, ST_PLAN_FISH=11;

    // ------------------------
    // Time base and animation tick
    // ------------------------
    reg [26:0] one_sec_count=0;
    reg sec_tick=0;
    reg [22:0] frame_count=0;
    reg frame_tick=0;
    always @(posedge CLK_100MHZ) begin
        sec_tick <= 1'b0;
        if (one_sec_count == 27'd99999999) begin
            one_sec_count <= 0;
            sec_tick <= 1'b1;
        end else one_sec_count <= one_sec_count + 1'b1;

        frame_tick <= 1'b0;
        if (frame_count == FRAME_CYCLES-1) begin
            frame_count <= 0;
            frame_tick <= 1'b1;
        end else frame_count <= frame_count + 1'b1;
    end

    // ------------------------
    // Encoder input conditioning
    // ------------------------
    reg [2:0] a_sync=3'b111, b_sync=3'b111, sw_sync=3'b111, swt_sync=3'b111;
    reg [16:0] button_sample=0;
    reg a_prev=1'b1, button_prev=1'b1;
    reg [3:0] button_stable=0;
    reg button_filtered=1'b1;
    reg rot_inc=0, rot_dec=0, press=0;
    always @(posedge CLK_100MHZ) begin
        a_sync  <= {a_sync[1:0], enc_a};
        b_sync  <= {b_sync[1:0], enc_b};
        sw_sync <= {sw_sync[1:0], enc_sw};
        swt_sync<= {swt_sync[1:0], enc_swt};
        rot_inc <= 0;
        rot_dec <= 0;
        press   <= 0;
        if (button_sample == 17'd99999) begin
            button_sample <= 0;
            if (a_sync[2] && !a_prev) begin
                if (b_sync[2]) rot_inc <= 1;
                else rot_dec <= 1;
            end
            a_prev <= a_sync[2];
            if (sw_sync[2] == button_filtered) button_stable <= 0;
            else if (button_stable == 4'd7) begin
                button_filtered <= sw_sync[2];
                button_stable <= 0;
            end else button_stable <= button_stable + 1'b1;
            if (button_prev && !button_filtered) press <= 1;
            button_prev <= button_filtered;
        end else button_sample <= button_sample + 1'b1;
    end

    // ------------------------
    // Main timekeeping and user settings
    // ------------------------
    reg [4:0] hours=12;
    reg [5:0] minutes=0, seconds=0;
    reg [2:0] edit_mode=MODE_RUN;
    reg [2:0] digit_theme=0;  // 0..7
    reg [1:0] scene_theme=0;  // 0..3

    always @(posedge CLK_100MHZ) begin
        if (press)
            edit_mode <= (edit_mode == MODE_SCENE) ? MODE_RUN : edit_mode + 1'b1;

        if (rot_inc || rot_dec) begin
            case (edit_mode)
                MODE_HOUR: hours <= rot_inc ? ((hours==23)?0:hours+1'b1)
                                           : ((hours==0)?23:hours-1'b1);
                MODE_MIN: begin
                    minutes <= rot_inc ? ((minutes==59)?0:minutes+1'b1)
                                       : ((minutes==0)?59:minutes-1'b1);
                    seconds <= 0;
                end
                MODE_COLOR: digit_theme <= rot_inc ? ((digit_theme==7)?0:digit_theme+1'b1)
                                                   : ((digit_theme==0)?7:digit_theme-1'b1);
                MODE_SCENE: scene_theme <= rot_inc ? (scene_theme+1'b1)
                                                   : (scene_theme-1'b1);
                default: begin end
            endcase
        end else if (sec_tick) begin
            if (seconds==59) begin
                seconds <= 0;
                if (minutes==59) begin
                    minutes <= 0;
                    hours <= (hours==23) ? 0 : hours+1'b1;
                end else minutes <= minutes+1'b1;
            end else seconds <= seconds+1'b1;
        end
    end

    // ------------------------
    // Aquarium motion state
    // ------------------------
    // Nine independent live centers; all movements are updated outside
    // the combinational pixel renderer. Fixed depths are replaced by gentle
    // per-animal vertical movement with bounded center positions.
    reg [8:0] animal_x [0:8];
    reg [7:0] animal_y [0:8];
    reg animal_right [0:8];
    reg [8:0] snap_animal_x [0:8];
    reg [7:0] snap_animal_y [0:8];
    reg [8:0] shown_animal_x [0:8];
    reg [7:0] shown_animal_y [0:8];
    reg snap_animal_right [0:8];
    reg shown_animal_right [0:8];
    reg [7:0] motion_phase=0;

    // Fish 7 (clownfish) leads fish 8 (blue tang) in a two-fish school.
    // Other animals pause, change direction, and adjust depth on separate
    // schedules. The jellyfish also retains its ROM tentacle animation.
    reg [6:0] wander_steps [0:7];
    reg [5:0] pause_ticks [0:7];
    reg depth_up [0:7];
    reg [15:0] motion_rng=16'hD57B;

    function [7:0] fish_level;
        input [3:0] id;
        begin
            case (id)
                4'd0: fish_level=8'd32;  // dolphin
                4'd1: fish_level=8'd57;  // swordfish
                4'd2: fish_level=8'd83;  // orca
                4'd3: fish_level=8'd106; // shrimp
                4'd4: fish_level=8'd132; // turtle
                4'd5: fish_level=8'd155; // crab
                4'd6: fish_level=8'd180; // jellyfish
                4'd7: fish_level=8'd202; // clownfish
                default: fish_level=8'd216; // blue tang follows clownfish
            endcase
        end
    endfunction

    function [5:0] animal_half_w;
        input [3:0] id;
        begin animal_half_w=(id<4'd3) ? 6'd28 : 6'd16; end
    endfunction
    function [4:0] animal_half_h;
        input [3:0] id;
        begin animal_half_h=(id==4'd6) ? 5'd16 : 5'd12; end
    endfunction

    integer ai_init;
    initial begin
        animal_x[0]=9'd55;  animal_x[1]=9'd135;
        animal_x[2]=9'd235; animal_x[3]=9'd75;
        animal_x[4]=9'd200; animal_x[5]=9'd110;
        animal_x[6]=9'd260; animal_x[7]=9'd155;
        animal_x[8]=9'd192;
        for(ai_init=0; ai_init<9; ai_init=ai_init+1) begin
            animal_y[ai_init]=fish_level(ai_init);
            animal_right[ai_init]=(ai_init[0]==0);
            snap_animal_x[ai_init]=animal_x[ai_init];
            snap_animal_y[ai_init]=animal_y[ai_init];
            shown_animal_x[ai_init]=animal_x[ai_init];
            shown_animal_y[ai_init]=animal_y[ai_init];
            snap_animal_right[ai_init]=animal_right[ai_init];
            shown_animal_right[ai_init]=animal_right[ai_init];
        end
        animal_right[8]=animal_right[7];
        snap_animal_right[8]=animal_right[7];
        shown_animal_right[8]=animal_right[7];
        for(ai_init=0; ai_init<8; ai_init=ai_init+1) begin
            wander_steps[ai_init]=0;
            pause_ticks[ai_init]=0;
            depth_up[ai_init]=(ai_init[0]==0);
        end
    end

    // PRNG state updates only at the motion tick, not per output pixel.
    always @(posedge CLK_100MHZ)
        if(frame_tick && swt_sync[2])
            motion_rng <= {motion_rng[14:0],
                            motion_rng[15]^motion_rng[13]^motion_rng[12]^motion_rng[10]};

    genvar af;
    generate for(af=0; af<8; af=af+1) begin: NATURAL_ANIMAL_MOTION
        localparam [2:0] STEP_SLOT=af%8;
        localparam integer FAST=(af<3 || af==7);
        localparam integer HW=(af<3)?28:16;
        // Stop clownfish early enough that its companion (+37 px) fits.
        localparam integer MAX_X=(af==7)?266:(319-HW);
        localparam integer MIN_X=HW;
        localparam integer BASE_Y=(af==0)?32:(af==1)?57:(af==2)?83:
                                  (af==3)?106:(af==4)?132:(af==5)?155:
                                  (af==6)?180:202;
        localparam integer WANDER_PERIOD=22+af*3;
        always @(posedge CLK_100MHZ) begin
            if (frame_tick && swt_sync[2]) begin
                // Pauses last 0.4..1.1 s and are counted at 40 Hz.
                if (pause_ticks[af]!=0) begin
                    pause_ticks[af] <= pause_ticks[af]-1'b1;
                end else if (((FAST && motion_phase[1:0]==STEP_SLOT[1:0]) ||
                              (!FAST && motion_phase[2:0]==STEP_SLOT)) &&
                             ((af==4 || af==5) ? !motion_phase[3] : 1'b1)) begin
                    if (animal_x[af] >= MAX_X && animal_right[af]) begin
                        animal_right[af] <= 1'b0;
                        pause_ticks[af] <= 6'd25 + af;
                    end else if (animal_x[af] <= MIN_X && !animal_right[af]) begin
                        animal_right[af] <= 1'b1;
                        pause_ticks[af] <= 6'd20 + af;
                    end else begin
                        if (animal_right[af]) animal_x[af] <= animal_x[af]+1'b1;
                        else animal_x[af] <= animal_x[af]-1'b1;

                        // Different visit intervals and pseudo-random choices
                        // stop the animals from repeating one synchronized loop.
                        if (wander_steps[af]==WANDER_PERIOD) begin
                            wander_steps[af] <= 0;
                            if (motion_rng[1:0]==(af%4)) begin
                                animal_right[af] <= ~animal_right[af];
                                pause_ticks[af] <= 6'd17 + af;
                            end else if (motion_rng[2:0]==((af+2)%8)) begin
                                pause_ticks[af] <= 6'd22 + af;
                            end
                        end else wander_steps[af] <= wander_steps[af]+1'b1;

                        // Gentle depth wandering. 1 vertical pixel every
                        // fourth step; ±6 around each species' home depth.
                        if (wander_steps[af][1:0]==2'b00) begin
                            if (animal_y[af] >= BASE_Y+6) depth_up[af] <= 0;
                            else if (animal_y[af] <= BASE_Y-6) depth_up[af] <= 1;
                            if (depth_up[af] && animal_y[af] < BASE_Y+6)
                                animal_y[af] <= animal_y[af]+1'b1;
                            else if (!depth_up[af] && animal_y[af] > BASE_Y-6)
                                animal_y[af] <= animal_y[af]-1'b1;
                        end
                    end
                end
            end
        end
    end endgenerate

    // These two fish travel together, while retaining different appearances
    // and slight differences in depth. The follower is one pixel/update behind.
    always @(posedge CLK_100MHZ) begin
        if(frame_tick && swt_sync[2]) begin
            animal_x[8] <= animal_x[7] + 9'd37;
            animal_y[8] <= animal_y[7] + 8'd14;
            animal_right[8] <= animal_right[7];
        end
    end

    // Background animation phases deliberately advance less often than the
    // fish logic. Each refresh group has its own generation counter.
    reg [7:0] bubble_phase=0;
    reg [7:0] grass_epoch=0;
    reg [7:0] snap_grass_epoch=0;
    reg [7:0] shown_grass_epoch=0;
    reg snap_jelly_phase=0, shown_jelly_phase=0;
    always @(posedge CLK_100MHZ) begin
        if(frame_tick && swt_sync[2] && motion_phase[2:0]==3'b000) begin
            bubble_phase <= bubble_phase + 1'b1; // about 5 Hz
            grass_epoch  <= grass_epoch  + 1'b1; // about 5 Hz
        end
    end

    // Move the wave lookup OUT of the combinational scene_pixel path.
    // Ten fixed, very small registers are updated only at motion ticks.
    // The snapshot is held constant for each screen update batch to avoid
    // mixing two grass positions in a single redraw.
    reg signed [4:0] grass_bend [0:9];
    reg signed [4:0] grass_snap [0:9];
    genvar gb;
    generate
        for (gb=0;gb<10;gb=gb+1) begin: PRECOMPUTE_GRASS
            initial grass_bend[gb]=0;
            always @(posedge CLK_100MHZ)
                if (frame_tick && swt_sync[2] && motion_phase[2:0]==3'b000)
                    grass_bend[gb] <= $signed(wave_s32(motion_phase + gb*23 + 8'd17) >>> 1);
        end
    endgenerate
    integer gs;
    integer gi_init;
    initial begin
        for(gi_init=0;gi_init<10;gi_init=gi_init+1)
            grass_snap[gi_init]=0;
    end

    always @(posedge CLK_100MHZ)
        if(frame_tick && swt_sync[2]) motion_phase <= motion_phase + 1'b1;

    // ------------------------
    // SPI transmitter
    // ------------------------
    reg spi_start=0;
    reg [7:0] spi_data=0;
    wire spi_busy, spi_done;
    aquarium_spi_tx #(.HALF_DIV(SPI_HALF_DIV)) spi (
        .clk(CLK_100MHZ), .start(spi_start), .data(spi_data),
        .sck(tft_sck), .mosi(tft_mosi), .busy(spi_busy), .done(spi_done));

    reg [3:0] state=ST_RST_LO;
    reg [1:0] tx_type=0; // 0 init, 1 window, 2 pixel
    reg [24:0] delay_count=0;
    reg [3:0] init_idx=0;
    reg [3:0] win_idx=0;
    reg [4:0] region=R_FULL;
    reg [8:0] x0=0, x1=9'd319, px=0;
    reg [7:0] y0=0, y1=8'd239, py=0;
    reg half=0;
    reg [15:0] pixel_hold=0;

    reg [4:0] snap_h=12;
    reg [5:0] snap_m=0;
    reg [2:0] snap_edit=0, snap_color=0;
    reg [1:0] snap_bg=0;
    reg [7:0] snap_wave=0;

    reg first_draw=1;
    reg [4:0] shown_h=12;
    reg [5:0] shown_m=0;
    reg [2:0] shown_mode=0, shown_color=0;
    reg [1:0] shown_bg=0;
    reg [7:0] shown_wave=0;
    reg frame_pending=0;
    reg animation_busy=0;
    reg [4:0] animation_stage=0;
    // Pipeline dirty bounds: stage 1 compares the old/new centers;
    // stage 2 expands to the actual rectangle dimensions.
    reg [8:0] dirty_left=0, dirty_right=0;
    reg [7:0] dirty_top=0, dirty_bottom=0;
    reg [3:0] dirty_id=0;


    // 160x120, 16-bit RGB565 indexed ROM (~300 Kbits, inferred block RAM).
    // Contains the user's reference aquarium image adapted to the TFT's 4:3
    // shape and 64-color palette. No graphics calculations for this artwork.
    (* rom_style = "block" *) reg [15:0] reef_rom [0:19199];
    initial $readmemh("reef_background.mem", reef_rom);
    wire [14:0] reef_addr = ({8'd0,py[7:1]} << 7) +
                            ({8'd0,py[7:1]} << 5) +
                            {7'd0,px[8:1]};
    reg [15:0] reef_rgb = 16'h0012;
    always @(posedge CLK_100MHZ) reef_rgb <= reef_rom[reef_addr];

    // Single-port synchronous sprite ROM, 9 x 2 x 64 x 32 entries.
    // Padded cells are transparent; index0 is transparent. 144 Kbits total.
    (* rom_style = "block" *) reg [3:0] fish_sprite_rom [0:36863];
    initial $readmemh("fish_sprites_4b.mem",fish_sprite_rom);
    reg [3:0] sprite_nibble=0;
    reg [3:0] sprite_id_q=0;
    reg sprite_inside_q=0;
    reg [3:0] sprite_id_comb=0;
    reg sprite_inside_comb=0;
    reg [5:0] sprite_local_x=0;
    reg [4:0] sprite_local_y=0;
    integer fish_probe;
    integer local_dx, local_dy;
    integer viewport_hw, viewport_hh;
    always @* begin
        sprite_id_comb=0;
        sprite_inside_comb=0;
        sprite_local_x=0;
        sprite_local_y=0;
        local_dx=0;
        local_dy=0;
        viewport_hw=16;
        viewport_hh=12;
        for(fish_probe=0;fish_probe<9;fish_probe=fish_probe+1) begin
            viewport_hw=(fish_probe<3) ? 28 : 16;
            viewport_hh=(fish_probe==6) ? 16 : 12;
            if (px >= snap_animal_x[fish_probe]-viewport_hw &&
                px <  snap_animal_x[fish_probe]+viewport_hw &&
                py >= snap_animal_y[fish_probe]-viewport_hh &&
                py <  snap_animal_y[fish_probe]+viewport_hh) begin
                sprite_inside_comb=1;
                sprite_id_comb=fish_probe;
                local_dx=px-(snap_animal_x[fish_probe]-viewport_hw);
                local_dy=py-(snap_animal_y[fish_probe]-viewport_hh);
                sprite_local_x=snap_animal_right[fish_probe] ? local_dx[5:0] :
                               (2*viewport_hw-1-local_dx);
                sprite_local_y=local_dy[4:0];
            end
        end
    end
    // Only the jellyfish has a 2-frame animation; all other fins remain
    // stationary regardless of frame tick. Changing phase every ~0.4 s.
    wire jelly_frame = (sprite_id_comb==4'd6) && snap_jelly_phase;
    wire [15:0] fish_sprite_addr={sprite_id_comb,jelly_frame,sprite_local_y,sprite_local_x};
    reg [15:0] fish_sprite_addr_q=0;
    // Two pipeline cycles: select a fish/address, then read the BRAM.
    // This breaks the long select-to-ROM critical path at 100 MHz.
    always @(posedge CLK_100MHZ) begin
        if(state==ST_REEF_FETCH) begin
            fish_sprite_addr_q <= fish_sprite_addr;
            sprite_id_q <= sprite_id_comb;
            sprite_inside_q <= sprite_inside_comb;
        end
        sprite_nibble <= fish_sprite_rom[fish_sprite_addr_q];
    end
    function [15:0] sprite_color;
        input [7:0] key;
        begin
            case(key)
    // Animal palettes: 4-bit index 0 transparent, 15 colors per species
            8'h00: sprite_color=16'h0000;
            8'h01: sprite_color=16'h1148;
            8'h02: sprite_color=16'h19EC;
            8'h03: sprite_color=16'h2B11;
            8'h04: sprite_color=16'h3C16;
            8'h05: sprite_color=16'h653A;
            8'h06: sprite_color=16'h8E3D;
            8'h07: sprite_color=16'hD79F;
            8'h08: sprite_color=16'hAEFD;
            8'h09: sprite_color=16'h224E;
            8'h0A: sprite_color=16'h4CD7;
            8'h0B: sprite_color=16'hF7FF;
            8'h0C: sprite_color=16'h08C5;
            8'h0D: sprite_color=16'h3310;
            8'h0E: sprite_color=16'h75BA;
            8'h0F: sprite_color=16'hFFFF;
            8'h10: sprite_color=16'h0000;
            8'h11: sprite_color=16'h1926;
            8'h12: sprite_color=16'h322B;
            8'h13: sprite_color=16'h4B2F;
            8'h14: sprite_color=16'h6433;
            8'h15: sprite_color=16'h9577;
            8'h16: sprite_color=16'hB69B;
            8'h17: sprite_color=16'hEFBF;
            8'h18: sprite_color=16'hD73D;
            8'h19: sprite_color=16'h2A4C;
            8'h1A: sprite_color=16'hC50B;
            8'h1B: sprite_color=16'hF7DF;
            8'h1C: sprite_color=16'h10C4;
            8'h1D: sprite_color=16'h3B2F;
            8'h1E: sprite_color=16'h9E3A;
            8'h1F: sprite_color=16'hFFDC;
            8'h20: sprite_color=16'h0000;
            8'h21: sprite_color=16'h08A4;
            8'h22: sprite_color=16'h10E4;
            8'h23: sprite_color=16'h2167;
            8'h24: sprite_color=16'h3A2A;
            8'h25: sprite_color=16'h6390;
            8'h26: sprite_color=16'hAD97;
            8'h27: sprite_color=16'hEF7E;
            8'h28: sprite_color=16'hFFFF;
            8'h29: sprite_color=16'h10C4;
            8'h2A: sprite_color=16'h8494;
            8'h2B: sprite_color=16'hFFFF;
            8'h2C: sprite_color=16'h0862;
            8'h2D: sprite_color=16'h29A8;
            8'h2E: sprite_color=16'hD73D;
            8'h2F: sprite_color=16'hFFFF;
            8'h30: sprite_color=16'h0000;
            8'h31: sprite_color=16'h38E2;
            8'h32: sprite_color=16'h6143;
            8'h33: sprite_color=16'h99C4;
            8'h34: sprite_color=16'hD2A5;
            8'h35: sprite_color=16'hEBC7;
            8'h36: sprite_color=16'hFD4D;
            8'h37: sprite_color=16'hFE94;
            8'h38: sprite_color=16'hFF17;
            8'h39: sprite_color=16'h7143;
            8'h3A: sprite_color=16'hF469;
            8'h3B: sprite_color=16'hFFFF;
            8'h3C: sprite_color=16'h20A2;
            8'h3D: sprite_color=16'hA204;
            8'h3E: sprite_color=16'hEDB0;
            8'h3F: sprite_color=16'hFFBB;
            8'h40: sprite_color=16'h0000;
            8'h41: sprite_color=16'h1965;
            8'h42: sprite_color=16'h2A87;
            8'h43: sprite_color=16'h3B49;
            8'h44: sprite_color=16'h444A;
            8'h45: sprite_color=16'h6D2C;
            8'h46: sprite_color=16'h9650;
            8'h47: sprite_color=16'hC734;
            8'h48: sprite_color=16'hE798;
            8'h49: sprite_color=16'h5245;
            8'h4A: sprite_color=16'hC50D;
            8'h4B: sprite_color=16'hFFFB;
            8'h4C: sprite_color=16'h1103;
            8'h4D: sprite_color=16'h2AC8;
            8'h4E: sprite_color=16'hA630;
            8'h4F: sprite_color=16'hFFFF;
            8'h50: sprite_color=16'h0000;
            8'h51: sprite_color=16'h40C3;
            8'h52: sprite_color=16'h6923;
            8'h53: sprite_color=16'h99A4;
            8'h54: sprite_color=16'hCA65;
            8'h55: sprite_color=16'hEB86;
            8'h56: sprite_color=16'hFCEA;
            8'h57: sprite_color=16'hFE31;
            8'h58: sprite_color=16'hFED5;
            8'h59: sprite_color=16'h8163;
            8'h5A: sprite_color=16'hFDED;
            8'h5B: sprite_color=16'hFFFF;
            8'h5C: sprite_color=16'h2081;
            8'h5D: sprite_color=16'hA1E4;
            8'h5E: sprite_color=16'hF449;
            8'h5F: sprite_color=16'hFF9A;
            8'h60: sprite_color=16'h0000;
            8'h61: sprite_color=16'h20A7;
            8'h62: sprite_color=16'h410B;
            8'h63: sprite_color=16'h61B1;
            8'h64: sprite_color=16'h8AF7;
            8'h65: sprite_color=16'hB47B;
            8'h66: sprite_color=16'hE5DD;
            8'h67: sprite_color=16'hF71F;
            8'h68: sprite_color=16'hF79F;
            8'h69: sprite_color=16'h30C9;
            8'h6A: sprite_color=16'hAF9F;
            8'h6B: sprite_color=16'hFFFF;
            8'h6C: sprite_color=16'h1064;
            8'h6D: sprite_color=16'h7215;
            8'h6E: sprite_color=16'hD57F;
            8'h6F: sprite_color=16'hFFFF;
            8'h70: sprite_color=16'h0000;
            8'h71: sprite_color=16'h20C2;
            8'h72: sprite_color=16'h6983;
            8'h73: sprite_color=16'hAA43;
            8'h74: sprite_color=16'hDB03;
            8'h75: sprite_color=16'hF444;
            8'h76: sprite_color=16'hFDA9;
            8'h77: sprite_color=16'hFEB0;
            8'h78: sprite_color=16'hFFDE;
            8'h79: sprite_color=16'h1926;
            8'h7A: sprite_color=16'hEED5;
            8'h7B: sprite_color=16'hFFFF;
            8'h7C: sprite_color=16'h10A3;
            8'h7D: sprite_color=16'h8162;
            8'h7E: sprite_color=16'hFD4A;
            8'h7F: sprite_color=16'hFFFF;
            8'h80: sprite_color=16'h0000;
            8'h81: sprite_color=16'h0928;
            8'h82: sprite_color=16'h11AE;
            8'h83: sprite_color=16'h1253;
            8'h84: sprite_color=16'h1B37;
            8'h85: sprite_color=16'h345C;
            8'h86: sprite_color=16'h761E;
            8'h87: sprite_color=16'hC75F;
            8'h88: sprite_color=16'hF688;
            8'h89: sprite_color=16'h116C;
            8'h8A: sprite_color=16'hFF2D;
            8'h8B: sprite_color=16'hFFFF;
            8'h8C: sprite_color=16'h08C6;
            8'h8D: sprite_color=16'h122F;
            8'h8E: sprite_color=16'h4CFB;
            8'h8F: sprite_color=16'hFFFF;
                default: sprite_color=16'h0000;
            endcase
        end
    endfunction
    wire [15:0] fish_rgb = sprite_color({sprite_id_q,sprite_nibble});

    function [8:0] init_word;
        input [3:0] idx;
        begin
            case (idx)
                 0: init_word={1'b0,8'h01};
                 1: init_word={1'b0,8'h11};
                 2: init_word={1'b0,8'h3A};
                 3: init_word={1'b1,8'h55};
                 4: init_word={1'b0,8'h36};
                 5: init_word={1'b1,8'h28};
                 6: init_word={1'b0,8'h29};
                 default: init_word=9'd0;
            endcase
        end
    endfunction
    function [8:0] frame_word;
        input [3:0] idx;
        input [8:0] ax,bx;
        input [7:0] ay,by;
        begin
            case(idx)
                 0:frame_word={1'b0,8'h2A};
                 1:frame_word={1'b1,7'd0,ax[8]};
                 2:frame_word={1'b1,ax[7:0]};
                 3:frame_word={1'b1,7'd0,bx[8]};
                 4:frame_word={1'b1,bx[7:0]};
                 5:frame_word={1'b0,8'h2B};
                 6:frame_word={1'b1,8'h00};
                 7:frame_word={1'b1,ay};
                 8:frame_word={1'b1,8'h00};
                 9:frame_word={1'b1,by};
                10:frame_word={1'b0,8'h2C};
                default: frame_word=9'd0;
            endcase
        end
    endfunction

    function [15:0] number_color;
        input [2:0] idx;
        begin
            case(idx)
                0:number_color=16'hFF2C; // gold
                1:number_color=16'h07FF; // cyan
                2:number_color=16'hFFFF; // white
                3:number_color=16'hF8BF; // pink
                4:number_color=16'h87E0; // mint
                5:number_color=16'hFD20; // orange
                6:number_color=16'hC7FF; // lavender
                7:number_color=16'hAFE5; // lime
                default:number_color=16'hFF2C;
            endcase
        end
    endfunction

    function integer wave_s8;
        input [7:0] phase;
        begin
            case(phase[7:4])
                4'h0: wave_s8=0;
                4'h1: wave_s8=2;
                4'h2: wave_s8=4;
                4'h3: wave_s8=6;
                4'h4: wave_s8=7;
                4'h5: wave_s8=6;
                4'h6: wave_s8=4;
                4'h7: wave_s8=2;
                4'h8: wave_s8=0;
                4'h9: wave_s8=-2;
                4'hA: wave_s8=-4;
                4'hB: wave_s8=-6;
                4'hC: wave_s8=-7;
                4'hD: wave_s8=-6;
                4'hE: wave_s8=-4;
                default: wave_s8=-2;
            endcase
        end
    endfunction

    // 32-point smoothed wave (amplitude -8..8) for subtle grass motion.
    // Unlike a hard left/right toggle, successive positions change gradually.
    function integer wave_s32;
        input [7:0] phase;
        begin
            case (phase[7:3])
                5'd0:  wave_s32=0;
                5'd1:  wave_s32=2;
                5'd2:  wave_s32=3;
                5'd3:  wave_s32=5;
                5'd4:  wave_s32=6;
                5'd5:  wave_s32=7;
                5'd6:  wave_s32=8;
                5'd7:  wave_s32=8;
                5'd8:  wave_s32=8;
                5'd9:  wave_s32=8;
                5'd10: wave_s32=8;
                5'd11: wave_s32=7;
                5'd12: wave_s32=6;
                5'd13: wave_s32=5;
                5'd14: wave_s32=3;
                5'd15: wave_s32=2;
                5'd16: wave_s32=0;
                5'd17: wave_s32=-2;
                5'd18: wave_s32=-3;
                5'd19: wave_s32=-5;
                5'd20: wave_s32=-6;
                5'd21: wave_s32=-7;
                5'd22: wave_s32=-8;
                5'd23: wave_s32=-8;
                5'd24: wave_s32=-8;
                5'd25: wave_s32=-8;
                5'd26: wave_s32=-8;
                5'd27: wave_s32=-7;
                5'd28: wave_s32=-6;
                5'd29: wave_s32=-5;
                5'd30: wave_s32=-3;
                default: wave_s32=-2;
            endcase
        end
    endfunction

    // Precomputed-bend grass pixel function. Every blade's bend is generated
    // by registers at animation ticks; NO sine lookup/multiply/division here.
    // Root is fixed. Upper 4 sections gradually bend; branches stay connected.
    function [15:0] grass_ink;
        input integer ix, iy, root;
        input signed [4:0] tip_bend;
        integer h, blade, blade_height, cx, b, branch_x;
        begin
            grass_ink = 16'h0000;
            h = 239-iy;
            blade = root >>> 5;
            // Vary blade heights without per-pixel multiply.
            case(blade)
                0: blade_height=54;
                1: blade_height=46;
                2: blade_height=59;
                3: blade_height=49;
                4: blade_height=61;
                5: blade_height=52;
                6: blade_height=57;
                7: blade_height=47;
                8: blade_height=60;
                9: blade_height=51;
                default:blade_height=0;
            endcase
            if(root>=0 && root<=319 && h>=0 && h<blade_height) begin
                // Piecewise curvature approximates a flexible seaweed blade.
                // Each adjacent section moves by <= 2 pixels.
                if      (h<12) cx=root;
                else if (h<24) cx=root+(tip_bend >>> 2);
                else if (h<36) cx=root+(tip_bend >>> 1);
                else if (h<48) cx=root+tip_bend-(tip_bend >>> 2);
                else           cx=root+tip_bend;
                if (ix==cx || ix==cx+1) begin
                    if (h<15) grass_ink=16'h03A0;
                    else if (h<32) grass_ink=16'h3605;
                    else grass_ink=16'h9FED;
                end
                // Tapered branches start at the stem, bend alongside it,
                // and terminate before the neighboring grass root.
                if(h>=18 && h<=28) begin
                    b=(h-18) >>> 1;
                    branch_x=cx+(((blade&1)==0)?b:-b);
                    if(ix==branch_x || (b<3 && ix==branch_x+1))
                        grass_ink=16'h66E8;
                end
                if(h>=32 && h<=42) begin
                    b=(h-32) >>> 1;
                    branch_x=cx+(((blade&2)==0)?-b:b);
                    if(ix==branch_x || (b<3 && ix==branch_x+1))
                        grass_ink=16'h87EA;
                end
            end
        end
    endfunction

    function [8:0] creature_left;
        input [8:0] center_x;
        begin creature_left=(center_x<9'd30)?9'd0:center_x-9'd30; end
    endfunction
    function [8:0] creature_right;
        input [8:0] center_x;
        begin creature_right=(center_x>9'd289)?9'd319:center_x+9'd30; end
    endfunction
    function [8:0] shark_left;
        input [8:0] center_x;
        begin shark_left=(center_x<9'd38)?9'd0:center_x-9'd38; end
    endfunction
    function [8:0] shark_right;
        input [8:0] center_x;
        begin shark_right=(center_x>9'd281)?9'd319:center_x+9'd38; end
    endfunction
    function [7:0] bubble_ypos;
        input [7:0] phase;
        input [7:0] offset;
        integer p;
        begin
            p = ((phase + offset) >> 1);
            bubble_ypos = 8'd224 - (p % 8'd198);
        end
    endfunction
    function [8:0] bubble_xpos;
        input [8:0] base;
        input [7:0] phase;
        input [7:0] offset;
        integer s;
        begin
            s = wave_s8(phase + offset);
            if (s < 0) bubble_xpos = base - (-s);
            else       bubble_xpos = base + s;
        end
    endfunction
    function [8:0] bubble_left;
        input [8:0] cx;
        begin bubble_left=(cx<9'd16)?9'd0:cx-9'd16; end
    endfunction
    function [8:0] bubble_right;
        input [8:0] cx;
        begin bubble_right=(cx>9'd303)?9'd319:cx+9'd16; end
    endfunction
    function [7:0] bubble_top;
        input [7:0] cy;
        begin bubble_top=(cy<8'd16)?8'd0:cy-8'd16; end
    endfunction
    function [7:0] bubble_bottom;
        input [7:0] cy;
        begin bubble_bottom=(cy>8'd223)?8'd239:cy+8'd16; end
    endfunction

    function [34:0] font5x7;
        input [7:0] ascii;
        begin
            case (ascii)
                "A":font5x7=35'b01110100011000111111100011000110001;
                "B":font5x7=35'b11110100011000111110100011000111110;
                "C":font5x7=35'b01111100001000010000100001000001111;
                "D":font5x7=35'b11110100011000110001100011000111110;
                "E":font5x7=35'b11111100001000011110100001000011111;
                "G":font5x7=35'b01111100001000010111100011000101111;
                "H":font5x7=35'b10001100011000111111100011000110001;
                "I":font5x7=35'b11111001000010000100001000010011111;
                "L":font5x7=35'b10000100001000010000100001000011111;
                "M":font5x7=35'b10001110111010110101100011000110001;
                "N":font5x7=35'b10001110011010110011100011000110001;
                "O":font5x7=35'b01110100011000110001100011000101110;
                "R":font5x7=35'b11110100011000111110101001001010001;
                "S":font5x7=35'b01111100001000001110000010000111110;
                "T":font5x7=35'b11111001000010000100001000010000100;
                "U":font5x7=35'b10001100011000110001100011000101110;
                "Y":font5x7=35'b10001100010101000100001000010000100;
                " ":font5x7=35'b0;
                default:font5x7=35'b0;
            endcase
        end
    endfunction
    function [7:0] mode_char;
        input [2:0] mode;
        input [2:0] idx;
        begin
            mode_char=" ";
            case(mode)
                MODE_RUN:   case(idx) 0:mode_char="R";1:mode_char="U";2:mode_char="N"; endcase
                MODE_HOUR:  case(idx) 0:mode_char="H";1:mode_char="O";2:mode_char="U";3:mode_char="R"; endcase
                MODE_MIN:   case(idx) 0:mode_char="M";1:mode_char="I";2:mode_char="N"; endcase
                MODE_COLOR: case(idx) 0:mode_char="C";1:mode_char="O";2:mode_char="L";3:mode_char="O";4:mode_char="R"; endcase
                MODE_SCENE: case(idx) 0:mode_char="B";1:mode_char="G"; endcase
                default: begin end
            endcase
        end
    endfunction
    function [6:0] seven_segments;
        input [3:0] val;
        begin
            case(val)
                0:seven_segments=7'b1111110;
                1:seven_segments=7'b0110000;
                2:seven_segments=7'b1101101;
                3:seven_segments=7'b1111001;
                4:seven_segments=7'b0110011;
                5:seven_segments=7'b1011011;
                6:seven_segments=7'b1011111;
                7:seven_segments=7'b1110000;
                8:seven_segments=7'b1111111;
                9:seven_segments=7'b1111011;
                default:seven_segments=7'b0000000;
            endcase
        end
    endfunction

    // V8.2: solid, readable beveled pixel numerals (no broken dashes).
    // Uses the same seven-segment selection as V8.1; only the stroke mask
    // changes, keeping the display driver and animation engine untouched.
    function tube_digit_hit;
        input integer dx,dy;
        input [3:0] val;
        reg [6:0] seg;
        reg hit;
        begin
            seg=seven_segments(val);
            hit=1'b0;
            if (dx>=0 && dx<48 && dy>=0 && dy<74) begin
                if (seg[6] && (((dy>=2 && dy<7) && dx>=12 && dx<36) ||
                               ((dy>=5 && dy<9) && dx>=9 && dx<39))) hit=1'b1;
                if (seg[5] && (((dx>=36 && dx<42) && dy>=8 && dy<34) ||
                               ((dx>=33 && dx<39) && dy>=13 && dy<29))) hit=1'b1;
                if (seg[4] && (((dx>=36 && dx<42) && dy>=37 && dy<65) ||
                               ((dx>=33 && dx<39) && dy>=43 && dy<60))) hit=1'b1;
                if (seg[3] && (((dy>=64 && dy<69) && dx>=12 && dx<36) ||
                               ((dy>=61 && dy<66) && dx>=9 && dx<39))) hit=1'b1;
                if (seg[2] && (((dx>=6 && dx<12) && dy>=37 && dy<65) ||
                               ((dx>=9 && dx<15) && dy>=43 && dy<60))) hit=1'b1;
                if (seg[1] && (((dx>=6 && dx<12) && dy>=8 && dy<34) ||
                               ((dx>=9 && dx<15) && dy>=13 && dy<29))) hit=1'b1;
                if (seg[0] && (((dy>=32 && dy<40) && dx>=12 && dx<36) ||
                               ((dy>=30 && dy<42) && dx>=9 && dx<39))) hit=1'b1;
            end
            tube_digit_hit=hit;
        end
    endfunction

    function small_bubble_hit;
        input integer dx,dy;
        integer adx,ady;
        begin
            adx=(dx<0)?-dx:dx;
            ady=(dy<0)?-dy:dy;
            small_bubble_hit = (((adx==0||adx==1) && ady==4) ||
                                ((ady==0||ady==1) && adx==4) ||
                                ((adx==2||adx==3) && ady==3) ||
                                ((ady==2||ady==3) && adx==3));
        end
    endfunction

    function [15:0] fish_pixel;
        input [8:0] ix; input [7:0] iy; input [8:0] cx; input [7:0] cy;
        input right; input [7:0] swim_phase;
        integer dx,dy,adx,ady,head_dx;
        begin
            dx=$signed({1'b0,ix})-$signed({1'b0,cx});
            dy=$signed({1'b0,iy})-$signed({1'b0,cy});
            adx=(dx<0)?-dx:dx; ady=(dy<0)?-dy:dy;
            head_dx = right ? dx : -dx;
            fish_pixel=16'h0000;
            if(adx<=15 && ady<=8 && (adx+ady*2)<=22) fish_pixel=16'hFFE0;
            if(head_dx>=-24 && head_dx<-12 && (ady <= ((head_dx+24)/2)+1) &&
               (swim_phase[1] ? ((dy+2)>=-8 && (dy+2)<=8) : ((dy-2)>=-8 && (dy-2)<=8))) fish_pixel=16'hFD20;
            if(head_dx>=-7 && head_dx<=3 && dy<=-7 && dy>=-11) fish_pixel=16'hFD20;
            if(head_dx>=-4 && head_dx<=0 && dy>=-5 && dy<=5) fish_pixel=16'hFD20;
            if(head_dx>=9 && head_dx<=11 && dy>=-3 && dy<=-1) fish_pixel=16'hFFFF;
            if(head_dx==11 && dy==-2) fish_pixel=16'h0020;
        end
    endfunction

    function [15:0] puffer_pixel;
        input [8:0] ix; input [7:0] iy; input [8:0] cx; input [7:0] cy; input leftward;
        integer dx,dy,adx,ady,hdx;
        begin
            dx=$signed({1'b0,ix})-$signed({1'b0,cx});
            dy=$signed({1'b0,iy})-$signed({1'b0,cy});
            adx=(dx<0)?-dx:dx; ady=(dy<0)?-dy:dy; hdx = leftward ? -dx : dx;
            puffer_pixel=16'h0000;
            if ((adx*adx + ady*ady) <= 82) puffer_pixel=16'hFEE0;
            if (((adx==9||adx==10) && ady<=1) || ((ady==8||ady==9) && adx<=1) ||
                ((adx>=6&&adx<=7)&&(ady>=5&&ady<=6)) || ((adx>=6&&adx<=7)&&(ady<=-5&&ady>=-6)) ||
                ((adx==8)&&(ady==3 || ady==-3))) puffer_pixel=16'hFD20;
            if (hdx<=-7 && hdx>=-13 && ady<=2) puffer_pixel=16'hFDA0;
            if (hdx>=3 && hdx<=5 && dy>=-1 && dy<=1) puffer_pixel=16'hFFFF;
            if (hdx==5 && dy==0) puffer_pixel=16'h0000;
        end
    endfunction

    function [15:0] seahorse_pixel;
        input [8:0] ix; input [7:0] iy; input [8:0] cx; input [7:0] cy; input [7:0] phase;
        integer dx,dy,tail;
        begin
            dx=$signed({1'b0,ix})-$signed({1'b0,cx});
            dy=$signed({1'b0,iy})-$signed({1'b0,cy});
            tail = wave_s8(phase + 8'd64) >>> 2;
            seahorse_pixel=16'h0000;
            // head and snout
            if ((dx>=5 && dx<=11 && dy>=-12 && dy<=-6) || (dx>=11 && dx<=14 && dy>=-10 && dy<=-8)) seahorse_pixel=16'hFCA5;
            // crest
            if ((dx>=4 && dx<=6 && dy>=-13 && dy<=-8) || (dx==3 && dy>=-11 && dy<=-9)) seahorse_pixel=16'hFD84;
            // neck / body / belly
            if ((dx>=0 && dx<=7 && dy>=-6 && dy<=10) || (dx>=-2 && dx<=4 && dy>=2 && dy<=14)) seahorse_pixel=16'hFCA5;
            if (dx>=2 && dx<=4 && dy>=-1 && dy<=10) seahorse_pixel=16'hFE0B;
            // dorsal ridge
            if (dx==-1 && dy>=-2 && dy<=9) seahorse_pixel=16'hFD84;
            // curled tail
            if ((dx==-4 && dy>=11 && dy<=15) || (dx==-5 && dy==16) || (dx==-6 && dy==17) ||
                (dx==-5 && dy==18) || (dx==-4 && dy==18) || (dx==-3 && dy==17+tail) ||
                (dx==-3 && dy==16+tail) || (dx==-2 && dy==15+tail)) seahorse_pixel=16'hFD84;
            // fins
            if ((dx>=-3 && dx<=-1 && dy>=1 && dy<=5) || (dx>=6 && dx<=8 && dy>=0 && dy<=4)) seahorse_pixel=16'hFDA0;
            // eye
            if (dx>=8 && dx<=9 && dy>=-10 && dy<=-9) seahorse_pixel=16'hFFFF;
            if (dx==9 && dy==-9) seahorse_pixel=16'h0000;
        end
    endfunction

    // Shark swims LEFT: pointed snout on -X and forked tail on +X.
    // The previous version faced right while its X coordinate moved left.
    function [15:0] shark_pixel;
        input [8:0] ix; input [7:0] iy;
        input [8:0] cx; input [7:0] cy;
        input [7:0] swim_phase;
        integer dx,dy,forward,af,ady,tail_spread,tail_dy,tail_shift;
        begin
            dx=$signed({1'b0,ix})-$signed({1'b0,cx});
            dy=$signed({1'b0,iy})-$signed({1'b0,cy});
            forward=-dx; // positive means forward = toward the LEFT
            af=(forward<0)?-forward:forward;
            ady=(dy<0)?-dy:dy;
            tail_shift=wave_s32(swim_phase+8'd37)>>>2;
            shark_pixel=16'h0000;
            // Hydrodynamic fusiform body and sharply tapered pointed nose.
            if (forward>=-22 && forward<=25 &&
                ady <= (9-(af>>>2))) shark_pixel=16'h8410;
            if (forward>=12 && forward<=28 &&
                ady <= ((29-forward)>>>2)) shark_pixel=16'h8410;
            // Lighter belly on lower half.
            if (forward>=-14 && forward<=20 && dy>=3 && dy<=6 &&
                (af+ady*2)<=30) shark_pixel=16'hBDF7;
            // Tall angular dorsal fin, peak near middle of body.
            if (forward>=-7 && forward<=7 && dy<=-8 &&
                dy>=(-20+(af<<1))) shark_pixel=16'h630C;
            // Pectoral fin projects diagonally downward/backward.
            if (forward>=-11 && forward<=0 && dy>=6 &&
                dy <= (14-((forward+5<0)? -(forward+5):(forward+5))))
                shark_pixel=16'h738E;
            // Distinct forked tail on the RIGHT, with slow side-to-side wag.
            if (forward<=-22 && forward>=-36) begin
                tail_spread=-forward-22;
                tail_dy=dy-tail_shift;
                if ((tail_dy<0 ? -tail_dy : tail_dy) <= (2+(tail_spread>>>1)) &&
                    (tail_dy<0 ? -tail_dy : tail_dy) >=
                      ((tail_spread>6)?((tail_spread-6)>>>1):0))
                    shark_pixel=16'h738E;
            end
            // Eye near the nose and two small gill marks.
            if (forward>=17 && forward<=18 && dy==-2) shark_pixel=16'hFFFF;
            if (forward==18 && dy==-2) shark_pixel=16'h0001;
            if ((forward==4 || forward==7) && dy>=1 && dy<=3)
                shark_pixel=16'h52AA;
        end
    endfunction

    function [15:0] octopus_pixel;
        input [8:0] ix; input [7:0] iy; input [8:0] cx; input [7:0] cy; input [7:0] phase;
        integer dx,dy,arm;
        begin
            dx=$signed({1'b0,ix})-$signed({1'b0,cx});
            dy=$signed({1'b0,iy})-$signed({1'b0,cy});
            octopus_pixel=16'h0000;
            if ((dx>=-12 && dx<=12 && dy>=-10 && dy<=8) && ((dx*dx)+(dy*dy) <= 180)) octopus_pixel=16'hF93F;
            if (dx>=-6 && dx<=-4 && dy>=-3 && dy<=-1) octopus_pixel=16'hFFFF;
            if (dx>=4  && dx<=6  && dy>=-3 && dy<=-1) octopus_pixel=16'hFFFF;
            if (dx==-5 && dy==-2) octopus_pixel=16'h0000;
            if (dx==5  && dy==-2) octopus_pixel=16'h0000;
            if (dy>=8 && dy<=22) begin
                arm = wave_s8(phase + 8'd24) >>> 2;
                if ((dx==-9+arm || dx==-5-arm || dx==-1+arm || dx==3-arm || dx==7+arm) && (dy>=8 && dy<=18)) octopus_pixel=16'hF13F;
                if ((dx==-10+arm || dx==-6-arm || dx==0+arm || dx==4-arm || dx==8+arm) && (dy>=18 && dy<=22)) octopus_pixel=16'hF13F;
            end
        end
    endfunction

    function [15:0] jelly_pixel;
        input [8:0] ix; input [7:0] iy; input [8:0] cx; input [7:0] cy; input [7:0] phase;
        integer dx,dy,sway;
        begin
            dx=$signed({1'b0,ix})-$signed({1'b0,cx});
            dy=$signed({1'b0,iy})-$signed({1'b0,cy});
            sway = wave_s8(phase + 8'd90) >>> 2;
            jelly_pixel=16'h0000;
            if ((dx>=-10 && dx<=10 && dy>=-10 && dy<=0) && ((dx*dx)+(dy*dy) <= 110)) jelly_pixel=16'hD2FF;
            if (dy==-1 && dx>=-8 && dx<=8) jelly_pixel=16'hA1FF;
            if ((dx==-6 || dx==-2 || dx==2 || dx==6) && dy>=1 && dy<=12+sway) jelly_pixel=16'hA1FF;
            if ((dx==-5 || dx==3) && dy>=5 && dy<=15-sway) jelly_pixel=16'hB3FF;
        end
    endfunction

    function [15:0] school_pixel;
        input [8:0] ix; input [7:0] iy; input [8:0] xbase; input [7:0] phase;
        integer sx,sy,dx,dy;
        begin
            school_pixel=16'h0000;
            // four tiny fish in a loose school
            sx = xbase;     sy = 8'd156;
            dx=$signed({1'b0,ix})-$signed(sx); dy=$signed({1'b0,iy})-$signed(sy);
            if (((dx>=-4 && dx<=1 && dy==0) || (dx>=-3 && dx<=0 && (dy==1||dy==-1)) || (dx==-5 && dy==0))) school_pixel=16'h7DFF;
            sx = xbase+10;  sy = 8'd160 + (wave_s8(phase+8'd30)>>>3);
            dx=$signed({1'b0,ix})-$signed(sx); dy=$signed({1'b0,iy})-$signed(sy);
            if (((dx>=-4 && dx<=1 && dy==0) || (dx>=-3 && dx<=0 && (dy==1||dy==-1)) || (dx==-5 && dy==0))) school_pixel=16'hB7FF;
            sx = xbase+19;  sy = 8'd154 + (wave_s8(phase+8'd60)>>>3);
            dx=$signed({1'b0,ix})-$signed(sx); dy=$signed({1'b0,iy})-$signed(sy);
            if (((dx>=-4 && dx<=1 && dy==0) || (dx>=-3 && dx<=0 && (dy==1||dy==-1)) || (dx==-5 && dy==0))) school_pixel=16'h9E9F;
            sx = xbase+29;  sy = 8'd162;
            dx=$signed({1'b0,ix})-$signed(sx); dy=$signed({1'b0,iy})-$signed(sy);
            if (((dx>=-4 && dx<=1 && dy==0) || (dx>=-3 && dx<=0 && (dy==1||dy==-1)) || (dx==-5 && dy==0))) school_pixel=16'h6DFF;
        end
    endfunction

    function [15:0] scene_pixel;
        input [8:0] x; input [7:0] y;
        input [4:0] hh; input [5:0] mm;
        input [2:0] mode,fg;
        input [1:0] background;
        input [7:0] wave;
        input [15:0] wallpaper_color;
        input [15:0] sprite_rgb;
        input sprite_valid;
        integer px,py,d,root,gi;
        integer letter_idx,letter_col,letter_row;
        integer dx,dy,bx,by,school_x;
        reg [7:0] ch;
        reg [34:0] glyph;
        reg [15:0] c,ink;
        reg [4:0] rr,bb;
        reg [5:0] gg;
        begin
            // Smooth full-screen background gradient.
            case(background)
                2'd0: begin rr = 5'd1 + (y>>7); gg = 6'd22 + ((8'd239-y)>>3); bb = 5'd14 + ((8'd239-y)>>4); end // ocean
                2'd1: begin rr = 5'd0;          gg = 6'd4  + ((8'd239-y)>>5); bb = 5'd8  + ((8'd239-y)>>4); end // night
                2'd2: begin rr = 5'd6  + ((8'd239-y)>>4); gg = 6'd10 + ((8'd239-y)>>4); bb = 5'd10 + ((8'd239-y)>>5); end // sunset
                default: begin rr = 5'd0 + (y>>7); gg = 6'd28 + ((8'd239-y)>>3); bb = 5'd12 + ((8'd239-y)>>5); end // lagoon
            endcase
            c = {rr,gg,bb};
            if (y < 26) begin
                if (background==2) c = 16'hAE1E;
                else if (background==1) c = 16'h1A12;
                else c = 16'h55FF;
            end

            // Small sparse twinkles, much lighter than earlier artifacts.
            if (((x[5:1]==5'd3) && (y[5:1]==5'd7)) || ((x[5:1]==5'd18) && (y[5:1]==5'd11)) ||
                ((x[5:1]==5'd28) && (y[5:1]==5'd5))) c = (background==1) ? 16'h5C7F : 16'h8D1F;

            // REEF: full pixel-art background from block ROM. Other three
            // background themes keep the original V8.7 flat gradients.
            if (background==2'd0) begin
                // Transparent numerals: preserve the reef wallpaper everywhere
                // except where the actual digits / other foreground objects draw.
                c = wallpaper_color;
            end

            // Status text.
            if (y>=6 && y<20 && x>=8 && x<96) begin
                letter_idx = (x-8)>>4;
                letter_col = ((x-8) & 15)>>1;
                letter_row = (y-6)>>1;
                ch = mode_char(mode, letter_idx);
                glyph = font5x7(ch);
                if (letter_col<5 && glyph[34-(letter_row*5+letter_col)]) c = (mode==MODE_RUN) ? 16'hD7FF : 16'hFFE0;
            end

            // Only isolated bubbles. Previous versions drew additional rings
            // at offsets from each bubble, creating unwanted dotted trails.
            // Keep gentle sinusoidal side-to-side motion and upward travel.
            bx=bubble_xpos(9'd42, wave, 8'd0);
            by=bubble_ypos(wave, 8'd0);
            dx=$signed({1'b0,x})-bx;
            dy=$signed({1'b0,y})-by;
            if (small_bubble_hit(dx,dy)) c=16'hCFFF;

            bx=bubble_xpos(9'd96, wave, 8'd48);
            by=bubble_ypos(wave, 8'd48);
            dx=$signed({1'b0,x})-bx;
            dy=$signed({1'b0,y})-by;
            if (small_bubble_hit(dx,dy)) c=16'hBFFF;

            bx=bubble_xpos(9'd182, wave, 8'd106);
            by=bubble_ypos(wave, 8'd106);
            dx=$signed({1'b0,x})-bx;
            dy=$signed({1'b0,y})-by;
            if (small_bubble_hit(dx,dy)) c=16'hD7FF;

            bx=bubble_xpos(9'd270, wave, 8'd172);
            by=bubble_ypos(wave, 8'd172);
            dx=$signed({1'b0,x})-bx;
            dy=$signed({1'b0,y})-by;
            if (small_bubble_hit(dx,dy)) c=16'hB7FF;

            // Redraw the grass over the exact same background used everywhere.
            // Check neighboring roots so a blade's tip cannot disappear when
            // it crosses the old artificial 16-pixel drawing-cell boundary.
            // Whole strip is redrawn each frame, restoring overlapping blades.
            if (y>=175) begin
                root = ((x>>5)<<5) + 16;
                for (gi=-1; gi<=1; gi=gi+1) begin
                    if (root+32*gi>=16 && root+32*gi<=304) begin
                        ink=grass_ink(x,y,root+32*gi,grass_snap[(root+32*gi)>>>5]);
                        if (ink!=0) c=ink;
                    end
                end
            end

            // Clock digits drawn BEFORE sprites so animals can swim across
            // the time and partially cover it, as if the numerals belong to
            // the aquarium scene rather than floating above everything.
            px=-1000; py=y-62; d=0;
            if      (x>=40  && x<88 ) begin px=x-40;  d=hh/10; end
            else if (x>=92  && x<140) begin px=x-92;  d=hh%10; end
            else if (x>=182 && x<230) begin px=x-182; d=mm/10; end
            else if (x>=234 && x<282) begin px=x-234; d=mm%10; end
            if (px>-100 && tube_digit_hit(px,py,d)) c = number_color(fg);
            dx=$signed({1'b0,x})-9'sd160;
            dy=$signed({1'b0,y})-8'sd92;
            if (small_bubble_hit(dx,dy)) c = number_color(fg);
            dy=$signed({1'b0,y})-8'sd118;
            if (small_bubble_hit(dx,dy)) c = number_color(fg);

            // Transparent animal pixels replace the existing scene, allowing
            // fish, turtle, jellyfish, seahorse, and starfish to swim through
            // the displayed time.
            if(sprite_valid) c = sprite_rgb;

            scene_pixel = c;
        end
    endfunction

    always @(posedge CLK_100MHZ) begin
        spi_start <= 1'b0;
        if (frame_tick && swt_sync[2]) frame_pending <= 1'b1;
        case(state)
            ST_RST_LO: begin
                tft_rst <= 1'b0;
                tft_cs  <= 1'b1;
                if (delay_count==25'd1999999) begin delay_count<=0; state<=ST_RST_HI; end
                else delay_count<=delay_count+1'b1;
            end
            ST_RST_HI: begin
                tft_rst <= 1'b1;
                if (delay_count==25'd14999999) begin delay_count<=0; state<=ST_INIT; end
                else delay_count<=delay_count+1'b1;
            end
            ST_INIT: begin
                if (init_idx<=4'd6) begin
                    tft_cs <= 1'b0;
                    tft_dc <= init_word(init_idx)>>8;
                    spi_data <= init_word(init_idx);
                    tx_type <= 0;
                    state <= ST_SEND;
                end else begin
                    tft_cs <= 1'b1;
                    state <= ST_IDLE;
                end
            end
            ST_IDLE: begin
                tft_cs <= 1'b1;
                if (animation_busy) begin
                    // Skip unchanged animals; one UNION rectangle covers the
                    // previous and current position, not two full rectangles.
                    // Draw every sprite within each selected dirty rectangle,
                    // preserving correct overlapping/foreground compositing.
                    if (animation_stage < 5'd9) begin
                        if (shown_animal_x[animation_stage] != snap_animal_x[animation_stage] ||
                            shown_animal_y[animation_stage] != snap_animal_y[animation_stage] ||
                            shown_animal_right[animation_stage] != snap_animal_right[animation_stage] ||
                            (animation_stage==5'd6 && shown_jelly_phase!=snap_jelly_phase)) begin
                            region <= R_FISH_FIRST + animation_stage;
                            dirty_id<=animation_stage[3:0];
                            dirty_left<= (shown_animal_x[animation_stage]<snap_animal_x[animation_stage]) ?
                                          shown_animal_x[animation_stage] : snap_animal_x[animation_stage];
                            dirty_right<= (shown_animal_x[animation_stage]>snap_animal_x[animation_stage]) ?
                                           shown_animal_x[animation_stage] : snap_animal_x[animation_stage];
                            dirty_top<= (shown_animal_y[animation_stage]<snap_animal_y[animation_stage]) ?
                                         shown_animal_y[animation_stage] : snap_animal_y[animation_stage];
                            dirty_bottom<= (shown_animal_y[animation_stage]>snap_animal_y[animation_stage]) ?
                                            shown_animal_y[animation_stage] : snap_animal_y[animation_stage];
                            state<=ST_PLAN_FISH;
                        end else animation_stage<=animation_stage+1'b1;
                    end else if (animation_stage < 5'd17) begin
                        // Bubbles change at ~5 Hz, not at every 40-Hz tick.
                        if (snap_wave == shown_wave) animation_stage<=5'd17;
                        else begin
                            win_idx<=0;
                            case(animation_stage)
                                5'd9:  begin region<=R_BUBBLE_FIRST+0; x0<=bubble_left(bubble_xpos(9'd42,shown_wave,8'd0));   x1<=bubble_right(bubble_xpos(9'd42,shown_wave,8'd0));   y0<=bubble_top(bubble_ypos(shown_wave,8'd0));   y1<=bubble_bottom(bubble_ypos(shown_wave,8'd0));   state<=ST_WINDOW; end
                                5'd10: begin region<=R_BUBBLE_FIRST+1; x0<=bubble_left(bubble_xpos(9'd42,snap_wave,8'd0));    x1<=bubble_right(bubble_xpos(9'd42,snap_wave,8'd0));    y0<=bubble_top(bubble_ypos(snap_wave,8'd0));    y1<=bubble_bottom(bubble_ypos(snap_wave,8'd0));    state<=ST_WINDOW; end
                                5'd11: begin region<=R_BUBBLE_FIRST+2; x0<=bubble_left(bubble_xpos(9'd96,shown_wave,8'd48));  x1<=bubble_right(bubble_xpos(9'd96,shown_wave,8'd48));  y0<=bubble_top(bubble_ypos(shown_wave,8'd48));  y1<=bubble_bottom(bubble_ypos(shown_wave,8'd48));  state<=ST_WINDOW; end
                                5'd12: begin region<=R_BUBBLE_FIRST+3; x0<=bubble_left(bubble_xpos(9'd96,snap_wave,8'd48));   x1<=bubble_right(bubble_xpos(9'd96,snap_wave,8'd48));   y0<=bubble_top(bubble_ypos(snap_wave,8'd48));   y1<=bubble_bottom(bubble_ypos(snap_wave,8'd48));   state<=ST_WINDOW; end
                                5'd13: begin region<=R_BUBBLE_FIRST+4; x0<=bubble_left(bubble_xpos(9'd182,shown_wave,8'd106)); x1<=bubble_right(bubble_xpos(9'd182,shown_wave,8'd106)); y0<=bubble_top(bubble_ypos(shown_wave,8'd106)); y1<=bubble_bottom(bubble_ypos(shown_wave,8'd106)); state<=ST_WINDOW; end
                                5'd14: begin region<=R_BUBBLE_FIRST+5; x0<=bubble_left(bubble_xpos(9'd182,snap_wave,8'd106));  x1<=bubble_right(bubble_xpos(9'd182,snap_wave,8'd106));  y0<=bubble_top(bubble_ypos(snap_wave,8'd106));  y1<=bubble_bottom(bubble_ypos(snap_wave,8'd106));  state<=ST_WINDOW; end
                                5'd15: begin region<=R_BUBBLE_FIRST+6; x0<=bubble_left(bubble_xpos(9'd270,shown_wave,8'd172)); x1<=bubble_right(bubble_xpos(9'd270,shown_wave,8'd172)); y0<=bubble_top(bubble_ypos(shown_wave,8'd172)); y1<=bubble_bottom(bubble_ypos(shown_wave,8'd172)); state<=ST_WINDOW; end
                                5'd16: begin region<=R_BUBBLE_FIRST+7; x0<=bubble_left(bubble_xpos(9'd270,snap_wave,8'd172));  x1<=bubble_right(bubble_xpos(9'd270,snap_wave,8'd172));  y0<=bubble_top(bubble_ypos(snap_wave,8'd172));  y1<=bubble_bottom(bubble_ypos(snap_wave,8'd172));  state<=ST_WINDOW; end
                                default: animation_stage<=5'd17;
                            endcase
                        end
                    end else if (animation_stage==5'd17) begin
                        if (snap_grass_epoch!=shown_grass_epoch) begin
                            region<=R_GRASS;
                            x0<=0; x1<=9'd319; y0<=8'd175; y1<=8'd239;
                            win_idx<=0; state<=ST_WINDOW;
                        end else animation_stage<=5'd18;
                    end else begin
                        // End of coherent update; published positions only
                        // change after all dirty regions were transmitted.
                        animation_busy<=0;
                        shown_wave<=snap_wave;
                        shown_grass_epoch<=snap_grass_epoch;
                        shown_jelly_phase<=snap_jelly_phase;
                        for(gs=0;gs<9;gs=gs+1) begin
                            shown_animal_x[gs]<=snap_animal_x[gs];
                            shown_animal_y[gs]<=snap_animal_y[gs];
                            shown_animal_right[gs]<=snap_animal_right[gs];
                        end
                    end
                end else if (first_draw || scene_theme!=shown_bg) begin
                    for(gs=0;gs<10;gs=gs+1) grass_snap[gs]<=grass_bend[gs];
                    snap_h<=hours; snap_m<=minutes; snap_edit<=edit_mode; snap_color<=digit_theme; snap_bg<=scene_theme;
                    for(gs=0;gs<9;gs=gs+1) begin
                        snap_animal_x[gs]<=animal_x[gs];
                        snap_animal_y[gs]<=animal_y[gs];
                        snap_animal_right[gs]<=animal_right[gs];
                    end
                    snap_wave<=bubble_phase;
                    snap_grass_epoch<=grass_epoch;
                    snap_jelly_phase<=motion_phase[4];
                    region<=R_FULL; x0<=0; x1<=9'd319; y0<=0; y1<=8'd239; win_idx<=0; state<=ST_WINDOW;
                end else if (hours!=shown_h || minutes!=shown_m || digit_theme!=shown_color) begin
                    snap_h<=hours; snap_m<=minutes; snap_edit<=edit_mode; snap_color<=digit_theme; snap_bg<=scene_theme;
                    snap_wave<=shown_wave;
                    snap_jelly_phase<=shown_jelly_phase;
                    region<=R_DIGITS; x0<=9'd34; x1<=9'd286; y0<=8'd58; y1<=8'd140; win_idx<=0; state<=ST_WINDOW;
                end else if (edit_mode!=shown_mode) begin
                    snap_h<=hours; snap_m<=minutes; snap_edit<=edit_mode; snap_color<=digit_theme; snap_bg<=scene_theme;
                    snap_wave<=shown_wave;
                    snap_jelly_phase<=shown_jelly_phase;
                    region<=R_STATUS; x0<=0; x1<=9'd100; y0<=0; y1<=8'd24; win_idx<=0; state<=ST_WINDOW;
                end else if (frame_pending && swt_sync[2]) begin
                    for(gs=0;gs<10;gs=gs+1) grass_snap[gs]<=grass_bend[gs];
                    frame_pending<=0;
                    animation_busy<=1'b1;
                    animation_stage<=0;
                    snap_h<=hours; snap_m<=minutes; snap_edit<=edit_mode; snap_color<=digit_theme; snap_bg<=scene_theme;
                    for(gs=0;gs<9;gs=gs+1) begin
                        snap_animal_x[gs]<=animal_x[gs];
                        snap_animal_y[gs]<=animal_y[gs];
                        snap_animal_right[gs]<=animal_right[gs];
                    end
                    snap_wave<=bubble_phase;
                    snap_grass_epoch<=grass_epoch;
                    snap_jelly_phase<=motion_phase[4];
                end else if (!swt_sync[2]) begin
                    frame_pending<=0;
                end
            end
            ST_PLAN_FISH: begin
                x0<=dirty_left-animal_half_w(dirty_id);
                x1<=dirty_right+animal_half_w(dirty_id)-1'b1;
                y0<=dirty_top-animal_half_h(dirty_id);
                y1<=dirty_bottom+animal_half_h(dirty_id)-1'b1;
                win_idx<=0; state<=ST_WINDOW;
            end
            ST_WINDOW: begin
                tft_cs<=1'b0;
                tft_dc<=frame_word(win_idx,x0,x1,y0,y1)>>8;
                spi_data<=frame_word(win_idx,x0,x1,y0,y1);
                tx_type<=1;
                state<=ST_SEND;
            end
            // One extra clock allows synchronous block-ROM data to settle
            // after pixel coordinate changes. This is not an SPI delay.
            ST_REEF_FETCH: state <= ST_SPRITE_READ;
            ST_SPRITE_READ: state <= ST_PIXEL;
            ST_PIXEL: begin
                tft_cs<=1'b0;
                tft_dc<=1'b1;
                if (!half) begin
                    pixel_hold<=scene_pixel(px,py,snap_h,snap_m,snap_edit,snap_color,snap_bg,snap_wave,reef_rgb,fish_rgb,(sprite_inside_q && sprite_nibble!=0));
                    spi_data<=scene_pixel(px,py,snap_h,snap_m,snap_edit,snap_color,snap_bg,snap_wave,reef_rgb,fish_rgb,(sprite_inside_q && sprite_nibble!=0))>>8;
                end else spi_data<=pixel_hold[7:0];
                tx_type<=2;
                state<=ST_SEND;
            end
            ST_SEND: if(!spi_busy) begin spi_start<=1'b1; state<=ST_WAIT; end
            ST_WAIT: if(spi_done) begin
                if (tx_type==0) begin
                    init_idx<=init_idx+1'b1;
                    if (init_idx==0 || init_idx==1) begin delay_count<=0; state<=ST_PAUSE; end
                    else state<=ST_INIT;
                end else if (tx_type==1) begin
                    if (win_idx==10) begin px<=x0; py<=y0; half<=0; state<=ST_REEF_FETCH; end
                    else begin win_idx<=win_idx+1'b1; state<=ST_WINDOW; end
                end else if (!half) begin
                    half<=1'b1;
                    state<=ST_PIXEL;
                end else begin
                    half<=1'b0;
                    if (px==x1) begin
                        px<=x0;
                        if (py==y1) begin
                            tft_cs<=1'b1;
                            state<=ST_IDLE;
                            case(region)
                                R_FULL: begin
                                    first_draw<=0;
                                    shown_bg<=snap_bg;
                                    shown_h<=snap_h; shown_m<=snap_m;
                                    shown_mode<=snap_edit; shown_color<=snap_color;
                                    shown_wave<=snap_wave;
                                    shown_grass_epoch<=snap_grass_epoch;
                                    shown_jelly_phase<=snap_jelly_phase;
                                    for(gs=0;gs<9;gs=gs+1) begin
                                        shown_animal_x[gs]<=snap_animal_x[gs];
                                        shown_animal_y[gs]<=snap_animal_y[gs];
                                        shown_animal_right[gs]<=snap_animal_right[gs];
                                    end
                                end
                                R_DIGITS: begin shown_h<=snap_h; shown_m<=snap_m; shown_color<=snap_color; end
                                R_STATUS: shown_mode<=snap_edit;
                                default: begin
                                    if(region>=R_FISH_FIRST && region<=R_GRASS)
                                        animation_stage<=animation_stage+1'b1;
                                end
                            endcase
                        end else begin py<=py+1'b1; state<=ST_REEF_FETCH; end
                    end else begin px<=px+1'b1; state<=ST_REEF_FETCH; end
                end
            end
            ST_PAUSE: begin
                if (delay_count==25'd11999999) begin delay_count<=0; state<=ST_INIT; end
                else delay_count<=delay_count+1'b1;
            end
            default: state<=ST_RST_LO;
        endcase
    end
endmodule

module aquarium_spi_tx #(
    parameter integer HALF_DIV=5
)(
    input wire clk,
    input wire start,
    input wire [7:0] data,
    output reg sck=0,
    output reg mosi=0,
    output reg busy=0,
    output reg done=0
);
    reg [3:0] div_count=0;
    reg [2:0] bitpos=0;
    reg [7:0] shift_data=0;
    always @(posedge clk) begin
        done<=0;
        if(!busy) begin
            sck<=0;
            if(start) begin
                busy<=1;
                div_count<=0;
                bitpos<=3'd7;
                shift_data<=data;
                mosi<=data[7];
            end
        end else if(div_count==HALF_DIV-1) begin
            div_count<=0;
            if(!sck) sck<=1;
            else begin
                sck<=0;
                if(bitpos==0) begin busy<=0; done<=1; end
                else begin
                    bitpos<=bitpos-1'b1;
                    mosi<=shift_data[bitpos-1'b1];
                end
            end
        end else div_count<=div_count+1'b1;
    end
endmodule
