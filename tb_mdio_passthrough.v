`timescale 1ns/1ps

module mdio_c45_slave_model #(
    parameter [4:0] PHY_ADDR = 5'd0,
    parameter [15:0] INITIAL_DATA = 16'h0000
) (
    input wire mdc,
    inout wire mdio
);
    reg [5:0] preamble_count;
    reg [6:0] frame_count;
    reg frame_active;
    reg first_start_bit;
    reg clause45_frame;
    reg opcode_msb;
    reg opcode_lsb;
    reg [4:0] phy_addr;
    reg [15:0] frame_data;
    reg [15:0] reg_addr;
    reg [15:0] reg_data;
    reg read_pending;
    reg drive_enable;
    reg drive_value;

    assign mdio = drive_enable ? drive_value : 1'bz;

    initial begin
        preamble_count = 0;
        frame_count = 0;
        frame_active = 0;
        first_start_bit = 0;
        clause45_frame = 0;
        opcode_msb = 0;
        opcode_lsb = 0;
        phy_addr = 0;
        frame_data = 0;
        reg_addr = 0;
        reg_data = INITIAL_DATA;
        read_pending = 0;
        drive_enable = 0;
        drive_value = 0;
    end

    always @(posedge mdc) begin
        if (!frame_active) begin
            if (mdio === 1'b1) begin
                if (preamble_count < 32)
                    preamble_count = preamble_count + 1'b1;
            end else if ((mdio === 1'b0) && preamble_count >= 32) begin
                frame_active = 1'b1;
                frame_count = 1;
                first_start_bit = mdio;
                clause45_frame = 0;
                opcode_msb = 0;
                opcode_lsb = 0;
                phy_addr = 0;
                frame_data = 0;
                read_pending = 0;
                preamble_count = 0;
            end else begin
                preamble_count = 0;
            end
        end else begin
            if (frame_count == 1)
                clause45_frame = !first_start_bit && (mdio === 1'b0);
            if (frame_count == 2)
                opcode_msb = (mdio === 1'b1);
            if (frame_count == 3)
                opcode_lsb = (mdio === 1'b1);
            if (clause45_frame && frame_count >= 4 && frame_count <= 8)
                phy_addr = {phy_addr[3:0], mdio};

            if (clause45_frame && frame_count >= 16 && frame_count <= 31)
                frame_data = {frame_data[14:0], mdio};

            if (clause45_frame && frame_count == 13) begin
                if (!opcode_msb && (phy_addr == PHY_ADDR))
                    read_pending = 0;
                else if (opcode_msb && (phy_addr == PHY_ADDR))
                    read_pending = 1;
                else
                    read_pending = 0;
            end

            if (clause45_frame && frame_count == 31) begin
                if (phy_addr == PHY_ADDR) begin
                    if (!opcode_msb && !opcode_lsb)
                        reg_addr = frame_data;
                    else if (!opcode_msb && opcode_lsb)
                        reg_data = frame_data;
                end
                read_pending = 0;
                frame_active = 0;
                frame_count = 0;
            end else begin
                frame_count = frame_count + 1'b1;
            end
        end
    end

    always @(negedge mdc) begin
        if (clause45_frame && read_pending && frame_count == 15) begin
            drive_enable = 1;
            drive_value = 1'b0;
        end else if (clause45_frame && read_pending &&
                     frame_count >= 16 && frame_count <= 31) begin
            drive_enable = 1;
            drive_value = reg_data[31-frame_count];
        end else begin
            drive_enable = 0;
        end
    end
endmodule

module tb_mdio_passthrough;
    reg clk_50M;
    reg reset_n;
    reg [3:0] host_sel;
    reg [8:0] m_mdc;
    tri [8:0] m_mdio;
    wire [9:0] s_mdc;
    tri [9:0] s_mdio;
    wire busy;
    reg [8:0] host_oe;
    reg [8:0] host_out;
    integer host_index;
    integer slave_index;
    integer phy;
    reg [15:0] test_data;
    reg [15:0] read_data;

    genvar g;
    generate
        for (g = 0; g < 9; g = g + 1) begin : g_host_drivers
            assign m_mdio[g] = host_oe[g] ? host_out[g] : 1'bz;
        end
        for (g = 0; g < 10; g = g + 1) begin : g_phy_models
            mdio_c45_slave_model #(
                .PHY_ADDR(g),
                .INITIAL_DATA(16'h0000)
            ) phy_model (
                .mdc(s_mdc[g]),
                .mdio(s_mdio[g])
            );
        end
    endgenerate

    mdio_passthrough dut (
        .clk_50M(clk_50M),
        .reset_n(reset_n),
        .host_sel(host_sel),
        .m_mdc(m_mdc),
        .m_mdio(m_mdio),
        .s_mdc(s_mdc),
        .s_mdio(s_mdio),
        .busy(busy)
    );

    always #10 clk_50M = ~clk_50M;

    task send_bit;
        input bit_value;
        begin
            m_mdc[host_index] = 1'b0;
            host_oe[host_index] = 1'b1;
            host_out[host_index] = bit_value;
            #200;
            m_mdc[host_index] = 1'b1;
            #200;
        end
    endtask

    task receive_bit;
        output bit_value;
        begin
            m_mdc[host_index] = 1'b0;
            host_oe[host_index] = 1'b0;
            #200;
            m_mdc[host_index] = 1'b1;
            #1;
            bit_value = m_mdio[host_index];
            #199;
        end
    endtask

    task send_field;
        input [31:0] field;
        input integer width;
        integer n;
        begin
            for (n = width - 1; n >= 0; n = n - 1)
                send_bit(field[n]);
        end
    endtask

    task c45_address;
        input [4:0] phy_address;
        input [15:0] register_address;
        integer n;
        begin
            for (n = 0; n < 32; n = n + 1)
                send_bit(1'b1);
            send_field(2'b00, 2);
            if (busy !== 1'b1)
                $fatal(1, "busy did not assert for Clause 45 frame");
            send_field(2'b00, 2);
            send_field(phy_address, 5);
            send_field(5'd1, 5);
            send_field(2'b10, 2);
            send_field(register_address, 16);
        end
    endtask

    task c45_write;
        input [4:0] phy_address;
        input [15:0] value;
        integer n;
        begin
            for (n = 0; n < 32; n = n + 1)
                send_bit(1'b1);
            send_field(2'b00, 2);
            if (busy !== 1'b1)
                $fatal(1, "busy did not assert for Clause 45 frame");
            send_field(2'b01, 2);
            send_field(phy_address, 5);
            send_field(5'd1, 5);
            send_field(2'b10, 2);
            send_field(value, 16);
        end
    endtask

    task c45_read;
        input [4:0] phy_address;
        output [15:0] value;
        integer n;
        reg sampled_bit;
        begin
            for (n = 0; n < 32; n = n + 1)
                send_bit(1'b1);
            send_field(2'b00, 2);
            if (busy !== 1'b1)
                $fatal(1, "busy did not assert for Clause 45 frame");
            send_field(2'b10, 2);
            send_field(phy_address, 5);
            send_field(5'd1, 5);
            receive_bit(sampled_bit);
            receive_bit(sampled_bit);
            value = 16'h0000;
            for (n = 15; n >= 0; n = n - 1) begin
                receive_bit(sampled_bit);
                value[n] = sampled_bit;
            end
            host_oe[host_index] = 1'b0;
            #100;
        end
    endtask

    initial begin
        clk_50M = 0;
        reset_n = 0;
        host_sel = 0;
        m_mdc = 0;
        host_oe = 0;
        host_out = 0;
        host_index = 0;
        #100;
        reset_n = 1;
        #100;

        for (slave_index = 0; slave_index < 8; slave_index = slave_index + 1) begin
            if (slave_index < 4) begin
                host_index = 0;
                host_sel = 0;
            end else begin
                host_index = 8;
                host_sel = 8;
            end
            #100;
            phy = slave_index;
            test_data = 16'hA520 ^ (slave_index * 16'h0111);
            c45_address(phy, 16'h0020 + slave_index);
            c45_write(phy, test_data);
            c45_address(phy, 16'h0020 + slave_index);
            c45_read(phy, read_data);
            if (read_data !== test_data) begin
                $display("FAIL: host %0d slave %0d expected %h, received %h",
                         host_index, slave_index, test_data, read_data);
                $fatal(1, "Clause 45 data mismatch");
            end
            if (busy !== 1'b0) begin
                $display("FAIL: busy did not return to idle");
                $fatal(1, "busy did not return to idle");
            end
            $display("PASS: host %0d slave %0d data %h",
                     host_index, slave_index, read_data);
        end

        $display("PASS: Clause 45 write/read checks completed");
        $finish;
    end
endmodule
