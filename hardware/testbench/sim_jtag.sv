//
// Copyright 2017 Jeff Bush
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import "DPI-C" function int init_jtag_socket(input int port);
import "DPI-C" function int poll_jtag_message(output logic[31:0] instructionLength,
    output logic[31:0] instruction, output logic[31:0] dataLength, output logic[63:0] data);
import "DPI-C" function int send_jtag_response(input logic[63:0] data);

//
// This simulates a JTAG host. It proxies messages from an external test program
// over a socket. It uses DPI to call into native code (jtag_socket.cpp) that polls
// the socket for new messages.
//

module sim_jtag
    (input                     clk,
    input                      reset,
    jtag_interface.master      jtag);

    typedef enum int {
        JTAG_RESET,
        JTAG_IDLE,
        JTAG_SELECT_DR_SCAN1,
        JTAG_SELECT_DR_SCAN2,
        JTAG_CAPTURE_DR,
        JTAG_SHIFT_DR,
        JTAG_EXIT1_DR,
        JTAG_PAUSE_DR,
        JTAG_EXIT2_DR,
        JTAG_UPDATE_DR,
        JTAG_SELECT_IR_SCAN,
        JTAG_CAPTURE_IR,
        JTAG_SHIFT_IR,
        JTAG_EXIT1_IR,
        JTAG_PAUSE_IR,
        JTAG_EXIT2_IR,
        JTAG_UPDATE_IR
    } jtag_state_t;

    localparam MAX_DATA_LEN = 64;
    localparam MAX_INSTRUCTION_LEN = 32;
    localparam CLOCK_DIVISOR = 7;

    int control_port_open;
    int instruction_length;
    logic[MAX_INSTRUCTION_LEN - 1:0] instruction_shift;
    int data_length;
    logic[MAX_DATA_LEN - 1:0] data_shift;
    logic[MAX_INSTRUCTION_LEN - 1:0] instruction;
    logic[MAX_DATA_LEN - 1:0] data;
    int shift_count;
    jtag_state_t current_state = JTAG_RESET;
    jtag_state_t next_state;
    int divider_count;

    initial
    begin
        int jtag_port;
        if ($value$plusargs("jtag_port=%d", jtag_port) != 0)
            control_port_open = init_jtag_socket(jtag_port);
        else
            control_port_open = 0;
    end

    always @(posedge clk, posedge reset)
    begin
        if (reset)
            divider_count <= 0;
        else if (divider_count == 0)
        begin
            jtag.tck <= !jtag.tck;
            divider_count <= CLOCK_DIVISOR;
        end
        else
            divider_count <= divider_count - 1;
    end

    always @(negedge jtag.tck)
    begin
        if (current_state == JTAG_SHIFT_DR)
            jtag.tdo <= data_shift[0];
        else
            jtag.tdo <= instruction_shift[0];
    end

    always @(posedge jtag.tck, posedge reset)
    begin
        if (reset)
            current_state <= JTAG_RESET;
        else
        begin
            current_state <= next_state;
            case (current_state)
                JTAG_CAPTURE_DR:
                begin
                    shift_count <= data_length;
                    data_shift <= data;
                end

                JTAG_CAPTURE_IR:
                begin
                    shift_count <= instruction_length;
                    instruction_shift <= instruction;
                end

                JTAG_SHIFT_DR:
                begin
                    // XXX the data_length + 1 seems like it's
                    // masking a bug somewhere else
                    data_shift <= (data_shift >> 1) | (MAX_DATA_LEN'(jtag.tdi)
                        << (data_length + 1));
                    shift_count <= shift_count - 1;
                end

                JTAG_SHIFT_IR:
                begin
                    // XXX the instruction_length + 1 seems like it's
                    // masking a bug somewhere else
                    instruction_shift <= (instruction_shift >> 1)
                        | (MAX_INSTRUCTION_LEN'(jtag.tdi)
                        << (instruction_length + 1));
                    shift_count <= shift_count - 1;
                end
            endcase
        end
    end

    always_comb
    begin
        next_state = current_state;
        jtag.trst = 0;
        case (current_state)
            JTAG_RESET:
            begin
                jtag.trst = 1;
                next_state = JTAG_IDLE;
                jtag.tms = 0;  // Go to idle state
            end

            JTAG_IDLE:
            begin
                if (control_port_open != 0)
                begin
                    if (poll_jtag_message(instruction_length, instruction, data_length, data) != 0)
                    begin
                        next_state = JTAG_SELECT_DR_SCAN1;
                        jtag.tms = 1;
                    end
                    else
                        jtag.tms = 0;
                end
                else
                    jtag.tms = 0;
            end

            // First time we go through this state, we jump to IR scan to load
            // the instruction
            JTAG_SELECT_DR_SCAN1:
            begin
                next_state = JTAG_SELECT_IR_SCAN;
                jtag.tms = 1;
            end

            // Go through this state again and go through the DR load
            JTAG_SELECT_DR_SCAN2:
            begin
                next_state = JTAG_CAPTURE_DR;
                jtag.tms = 0;
            end

            JTAG_CAPTURE_DR:
            begin
                next_state = JTAG_SHIFT_DR;
                jtag.tms = 0;
            end

            JTAG_SHIFT_DR:
            begin
                if (shift_count == 0)
                begin
                    jtag.tms = 1;
                    next_state = JTAG_EXIT1_DR;
                end
                else
                    jtag.tms = 0;
            end

            JTAG_EXIT1_DR:
            begin
                jtag.tms = 0;
                next_state = JTAG_PAUSE_DR;
            end

            JTAG_PAUSE_DR:
            begin
                jtag.tms = 1;
                next_state = JTAG_EXIT2_DR;
            end

            JTAG_EXIT2_DR:
            begin
                jtag.tms = 1;
                next_state = JTAG_UPDATE_DR;
            end

            JTAG_UPDATE_DR:
            begin
                jtag.tms = 0;
                send_jtag_response(data_shift);
                next_state = JTAG_IDLE;
            end

            JTAG_SELECT_IR_SCAN:
            begin
                jtag.tms = 0;
                next_state = JTAG_CAPTURE_IR;
            end

            JTAG_CAPTURE_IR:
            begin
                jtag.tms = 0;
                next_state = JTAG_SHIFT_IR;
            end

            JTAG_SHIFT_IR:
            begin
                if (shift_count == 0)
                begin
                    jtag.tms = 1;
                    next_state = JTAG_EXIT1_IR;
                end
                else
                    jtag.tms = 0;
            end

            JTAG_EXIT1_IR:
            begin
                jtag.tms = 0;
                next_state = JTAG_PAUSE_IR;
            end

            JTAG_PAUSE_IR:
            begin
                jtag.tms = 1;
                next_state = JTAG_EXIT2_IR;
            end

            JTAG_EXIT2_IR:
            begin
                jtag.tms = 1;
                next_state = JTAG_UPDATE_IR;
            end

            JTAG_UPDATE_IR:
            begin
                jtag.tms = 1;
                next_state = JTAG_SELECT_DR_SCAN2;
            end

            default:
                next_state = JTAG_RESET;
        endcase
    end
endmodule
