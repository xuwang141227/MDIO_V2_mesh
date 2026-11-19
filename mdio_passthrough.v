`timescale 1ns/1ps

module mdio_passthrough #(
    parameter [15:0] SLAVE0_CFG = 16'h8001,
    parameter [15:0] SLAVE1_CFG = 16'h8001,
    parameter [15:0] SLAVE2_CFG = 16'h8001,
    parameter [15:0] SLAVE3_CFG = 16'h8001,
    parameter [15:0] SLAVE4_CFG = 16'h8100,
    parameter [15:0] SLAVE5_CFG = 16'h8100,
    parameter [15:0] SLAVE6_CFG = 16'h8100,
    parameter [15:0] SLAVE7_CFG = 16'h8100,
    parameter [15:0] SLAVE8_CFG = 16'h0000,
    parameter [15:0] SLAVE9_CFG = 16'h0000
) (
    input wire clk_50M,
    input wire reset_n,
    input wire [3:0] host_sel,
    input wire [8:0] m_mdc,
    inout wire [8:0] m_mdio,
    output wire [9:0] s_mdc,
    inout wire [9:0] s_mdio,
    output reg busy
);

    reg mdc_meta;
    reg mdc_sync;
    reg mdc_prev;
    reg mdio_meta;
    reg mdio_sync;
    reg [3:0] host_sel_prev;
    reg [5:0] preamble_count;
    reg [6:0] frame_count;
    reg frame_active;
    reg clause45_frame;
    reg first_start_bit;
    reg opcode_msb;
    reg read_command;
    reg read_window;

    wire selected_mdc = (host_sel < 4'd9) ? m_mdc[host_sel] : 1'b0;
    wire selected_mdio = (host_sel < 4'd9) ? m_mdio[host_sel] : 1'b1;
    wire [9:0] route_enable;
    reg read_data_or;
    integer i;

    function [15:0] slave_config;
        input [3:0] port_num;
        begin
            case (port_num)
                4'd0: slave_config = SLAVE0_CFG;
                4'd1: slave_config = SLAVE1_CFG;
                4'd2: slave_config = SLAVE2_CFG;
                4'd3: slave_config = SLAVE3_CFG;
                4'd4: slave_config = SLAVE4_CFG;
                4'd5: slave_config = SLAVE5_CFG;
                4'd6: slave_config = SLAVE6_CFG;
                4'd7: slave_config = SLAVE7_CFG;
                4'd8: slave_config = SLAVE8_CFG;
                4'd9: slave_config = SLAVE9_CFG;
                default: slave_config = 16'h0000;
            endcase
        end
    endfunction

    function valid_host_map;
        input [8:0] host_map;
        begin
            valid_host_map = (host_map != 9'b0) &&
                             ((host_map & (host_map - 9'b1)) == 9'b0);
        end
    endfunction

    function host_is_selected;
        input [8:0] host_map;
        input [3:0] host_num;
        begin
            case (host_num)
                4'd0: host_is_selected = host_map[0];
                4'd1: host_is_selected = host_map[1];
                4'd2: host_is_selected = host_map[2];
                4'd3: host_is_selected = host_map[3];
                4'd4: host_is_selected = host_map[4];
                4'd5: host_is_selected = host_map[5];
                4'd6: host_is_selected = host_map[6];
                4'd7: host_is_selected = host_map[7];
                4'd8: host_is_selected = host_map[8];
                default: host_is_selected = 1'b0;
            endcase
        end
    endfunction

    genvar port_index;
    generate
        for (port_index = 0; port_index < 10; port_index = port_index + 1) begin : g_slave_ports
            wire [15:0] config_word;
            assign config_word = slave_config(port_index);
            assign route_enable[port_index] =
                config_word[15] && valid_host_map(config_word[8:0]) &&
                host_is_selected(config_word[8:0], host_sel);
            assign s_mdc[port_index] =
                route_enable[port_index] ? selected_mdc : 1'b0;
            assign s_mdio[port_index] =
                (route_enable[port_index] && !read_window) ? selected_mdio : 1'bz;
        end

        for (port_index = 0; port_index < 9; port_index = port_index + 1) begin : g_host_ports
            assign m_mdio[port_index] =
                ((host_sel == port_index) && read_window) ? read_data_or : 1'bz;
        end
    endgenerate

    always @* begin
        read_data_or = 1'b0;
        for (i = 0; i < 10; i = i + 1) begin
            if (route_enable[i] && s_mdio[i])
                read_data_or = 1'b1;
        end
    end

    always @(posedge clk_50M or negedge reset_n) begin
        if (!reset_n) begin
            mdc_meta <= 1'b0;
            mdc_sync <= 1'b0;
            mdc_prev <= 1'b0;
            mdio_meta <= 1'b1;
            mdio_sync <= 1'b1;
            host_sel_prev <= 4'hf;
            preamble_count <= 6'd0;
            frame_count <= 7'd0;
            frame_active <= 1'b0;
            clause45_frame <= 1'b0;
            first_start_bit <= 1'b0;
            opcode_msb <= 1'b0;
            read_command <= 1'b0;
            read_window <= 1'b0;
            busy <= 1'b0;
        end else begin
            mdc_meta <= selected_mdc;
            mdc_sync <= mdc_meta;
            mdc_prev <= mdc_sync;
            mdio_meta <= selected_mdio;
            mdio_sync <= mdio_meta;

            if (host_sel != host_sel_prev) begin
                host_sel_prev <= host_sel;
                preamble_count <= 6'd0;
                frame_count <= 7'd0;
                frame_active <= 1'b0;
                clause45_frame <= 1'b0;
                read_command <= 1'b0;
                read_window <= 1'b0;
                busy <= 1'b0;
            end else if (mdc_sync && !mdc_prev) begin
                if (!frame_active) begin
                    if (mdio_sync) begin
                        if (preamble_count < 6'd32)
                            preamble_count <= preamble_count + 1'b1;
                    end else if (preamble_count >= 6'd32) begin
                        frame_active <= 1'b1;
                        frame_count <= 7'd1;
                        first_start_bit <= mdio_sync;
                        clause45_frame <= 1'b0;
                        opcode_msb <= 1'b0;
                        read_command <= 1'b0;
                        preamble_count <= 6'd0;
                        busy <= 1'b1;
                    end else begin
                        preamble_count <= 6'd0;
                    end
                end else begin
                    if (frame_count == 7'd1)
                        clause45_frame <= !first_start_bit && !mdio_sync;
                    if (frame_count == 7'd2)
                        opcode_msb <= mdio_sync;
                    if (frame_count == 7'd3)
                        read_command <= opcode_msb;

                    if (frame_count == 7'd13 && read_command)
                        read_window <= 1'b1;

                    if (frame_count == 7'd31) begin
                        frame_active <= 1'b0;
                        frame_count <= 7'd0;
                        read_window <= 1'b0;
                        busy <= 1'b0;
                    end else begin
                        frame_count <= frame_count + 1'b1;
                    end
                end
            end
        end
    end

endmodule
