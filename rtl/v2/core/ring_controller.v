//
// Copyright (C) 2014 Jeff Bush
// 
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
// 
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
// 
// You should have received a copy of the GNU Library General Public
// License along with this library; if not, write to the
// Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
// Boston, MA  02110-1301, USA.
//

`include "defines.v"

//
// The ring controller processes packets passing through the ring and
// inserts messages where appropriate.  It sets control signals to update L1
// caches. Packets flow through a three stage pipeline.
// Stage 1: Issue address to tag RAM to snoop if the data is present.
//   Also check if there is a pending miss for the packet address
// Stage 2: Update tag memory and issue read request to data memory if there
//   is a writeback
// Stage 3: Issue signals to update data memory.
//

module ring_controller
	#(parameter NODE_ID = 0)
	(input                                  clk,
	input                                  reset,
	
	// Ring interface
	input ring_packet_t                    packet_in,
	output ring_packet_t                   packet_out,
	
	// To instruction pipeline
	output [`L1D_WAYS - 1:0]               rc_dtag_update_en_oh,
	output l1d_set_idx_t                   rc_dtag_update_set,
	output l1d_tag_t                       rc_dtag_update_tag,
	output cache_line_state_t              rc_dtag_update_state,
	output                                 rc_ddata_update_en,
	output l1d_way_idx_t                   rc_ddata_update_way,
	output l1d_set_idx_t                   rc_ddata_update_set,
	output [`CACHE_LINE_BITS - 1:0]        rc_ddata_update_data,
	output [`THREADS_PER_CORE - 1:0]       rc_dcache_wake_oh,
	output                                 rc_ddata_read_en,
	output l1d_set_idx_t                   rc_ddata_read_set,
 	output l1d_way_idx_t                   rc_ddata_read_way,
	output logic                           rc_snoop_en,
	output l1d_set_idx_t                   rc_snoop_set,
	input cache_line_state_t               dt_snoop_state[`L1D_WAYS],
	input l1d_tag_t                        dt_snoop_tag[`L1D_WAYS],
	input l1d_way_idx_t                    dt_snoop_lru,
	input                                  dd_cache_miss,
	input scalar_t                         dd_cache_miss_addr,
	input                                  dd_cache_miss_store,
	input thread_idx_t                     dd_cache_miss_thread_idx,
	input logic[`CACHE_LINE_BITS - 1:0]    dd_ddata_read_data);

	ring_packet_t rc1_packet;
	logic rc1_dcache_miss_pending;
	logic[`THREADS_PER_CORE - 1:0] rc1_dcache_miss_entry;
	logic[`L1D_WAYS - 1:0] rc1_snoop_hit_way_oh;
	logic[`L1D_WAYS - 1:0] rc1_fill_way_oh;	
	l1d_way_idx_t rc1_fill_way_idx;
	l1d_addr_t rc1_cache_addr;
	pending_miss_state_t rc1_pending_miss_state;
	logic rc2_dcache_miss_pending;
	ring_packet_t rc2_packet;
	logic[`THREADS_PER_CORE - 1:0] rc2_dcache_miss_entry;
	l1d_addr_t rc2_cache_addr;
	l1d_way_idx_t rc1_snoop_hit_way_idx;
	logic dcache_snoop_hit;
	l1d_way_idx_t rc2_fill_way_idx;
	logic rc2_need_writeback;
	scalar_t rc2_evicted_line_addr;
	ring_packet_t packet_out_nxt;
	logic dcache_miss_ready;
	scalar_t dcache_miss_address;
	logic dcache_miss_store;
	logic dcache_miss_ack;
		
	l1_miss_queue dcache_miss_queue(
		// Enqueue new requests
		.cache_miss(dd_cache_miss),
		.cache_miss_addr(dd_cache_miss_addr),
		.cache_miss_store(dd_cache_miss_store),
		.cache_miss_thread_idx(dd_cache_miss_thread_idx),

		// Check existing transactions
		.snoop_en(packet_in.valid),
		.snoop_addr(packet_in.address),
		.snoop_hit(dcache_snoop_hit),
		.snoop_hit_entry(rc1_dcache_miss_entry),
		.snoop_state(rc1_pending_miss_state),

		// Wake threads when a transaction is complete
		.wake_en(rc2_packet.valid && rc2_dcache_miss_pending),
		.wake_entry(rc2_dcache_miss_entry),

		// Insert new requests into ring
		.request_ready(dcache_miss_ready),
		.request_address(dcache_miss_address),
		.request_store(dcache_miss_store),      
		.request_ack(dcache_miss_ack),
		.*);

	//////////////////////////////////////////////////////////////////////////////
	// Stage 1.  Issue snoop request to L1 tags and check miss queue.
	//////////////////////////////////////////////////////////////////////////////
	assign rc_snoop_en = packet_in.valid;
	assign rc_snoop_set = packet_in[`CACHE_LINE_OFFSET_WIDTH+:$clog2(`L1D_SETS)];
	
	always_ff @(posedge clk, posedge reset)
	begin
		if (reset)
			rc1_packet <= 0;
		else
			rc1_packet <= packet_in;
	end

	assign rc1_cache_addr = rc1_packet.address;
	assign rc1_dcache_miss_pending = dcache_snoop_hit && rc1_packet.valid;

	genvar way_idx;
	generate
		for (way_idx = 0; way_idx < `L1D_WAYS; way_idx++)
		begin
			assign rc1_snoop_hit_way_oh[way_idx] = dt_snoop_tag[way_idx] == rc1_cache_addr.tag 
				&& dt_snoop_state[way_idx] != CL_STATE_INVALID;
		end
	endgenerate

	one_hot_to_index #(.NUM_SIGNALS(`L1D_WAYS)) convert_snoop_hit(
		.index(rc1_snoop_hit_way_idx),
		.one_hot(rc1_snoop_hit_way_oh));

	assign rc1_fill_way_idx = |rc1_snoop_hit_way_oh ? rc1_snoop_hit_way_idx : dt_snoop_lru;

	index_to_one_hot #(.NUM_SIGNALS(`L1D_WAYS)) convert_tag_update(
		.index(rc1_fill_way_idx),
		.one_hot(rc1_fill_way_oh));
	
	//////////////////////////////////////////////////////////////////////////////
	// Stage 2. Update the tag and read an old line if one is to be evicted
	//////////////////////////////////////////////////////////////////////////////

	assign rc_dtag_update_en_oh = rc1_fill_way_oh && {`L1D_WAYS{rc1_packet.valid}};
	assign rc_dtag_update_tag = rc1_cache_addr.tag;	
	assign rc_dtag_update_set = rc1_cache_addr.set_idx;
	assign rc_dtag_update_state = rc1_pending_miss_state == PM_READ_PENDING ? CL_STATE_SHARED
		: CL_STATE_MODIFIED;

	assign rc_ddata_read_en = rc1_packet.valid && rc1_dcache_miss_pending;
	assign rc_ddata_read_set = rc1_cache_addr.set_idx;
	assign rc_ddata_read_way = rc1_fill_way_idx;
	
	always_ff @(posedge clk, posedge reset)
	begin
		if (reset)
		begin
			rc2_fill_way_idx <= 0;
			rc2_packet <= 0;
			rc2_dcache_miss_entry <= 0;
			rc2_dcache_miss_pending <= 0;
		end
		else
		begin
			rc2_fill_way_idx <= rc1_fill_way_idx;
			rc2_packet <= rc1_packet;
			rc2_dcache_miss_entry <= rc1_dcache_miss_entry;
			rc2_dcache_miss_pending <= rc1_dcache_miss_pending;
			rc2_need_writeback <= dt_snoop_state[rc1_snoop_hit_way_idx] == CL_STATE_MODIFIED
				&& rc1_packet.valid;
			rc2_evicted_line_addr <= {dt_snoop_tag[rc1_snoop_hit_way_idx], rc1_cache_addr.set_idx, {`CACHE_LINE_OFFSET_WIDTH{1'b0}}};
		end
	end
	
	//////////////////////////////////////////////////////////////////////////////
	// Stage 3. Update cache data.
	// If there is an empty ring slot and a request is pending, issue it now.
	// Wake up threads if necessary.
	//////////////////////////////////////////////////////////////////////////////

	assign rc2_cache_addr = rc2_packet.address;
	assign rc_ddata_update_en = rc2_packet.valid && rc2_dcache_miss_pending && rc2_packet.ack;
	assign rc_ddata_update_way = rc2_fill_way_idx;	
	assign rc_ddata_update_set = rc2_cache_addr.set_idx;
	assign rc_ddata_update_data = rc2_packet.data;

	always_comb
	begin
		dcache_miss_ack = 0;
		if (rc2_packet.valid)
		begin
			if (rc2_packet.dest_node != NODE_ID || !rc2_packet.ack)
			begin
				// Forward packet for another node on (or retry nacked packet)
				assert(!rc2_need_writeback);
				packet_out_nxt = rc2_packet;	
			end
			else if (rc2_need_writeback)
			begin
				// Insert L2 writeback packet
				packet_out_nxt.valid = 1;
				packet_out_nxt.packet_type = PKT_L2_WRITEBACK;
				packet_out_nxt.ack = 0;
				packet_out_nxt.l2_miss = 0;
				packet_out_nxt.dest_node = 0;	// XXX L2 node ID
				packet_out_nxt.address = rc2_evicted_line_addr;
				packet_out_nxt.data = dd_ddata_read_data;
			end
			else
			begin
				// To avoid starvation, a node that consumes a response from the ring
				// leaves that slot empty (unless an L2 writeback is necessary)
				packet_out_nxt = 0;
			end
		end
		else if (dcache_miss_ready)
		begin
			// Inject request packet into ring
			dcache_miss_ack = 1;
			packet_out_nxt.valid = 1;
			packet_out_nxt.packet_type = dcache_miss_store ? PKT_WRITE_INVALIDATE : PKT_READ_SHARED;
			packet_out_nxt.ack = 0;
			packet_out_nxt.l2_miss = 0;
			packet_out_nxt.dest_node = NODE_ID;
			packet_out_nxt.address = dcache_miss_address;
		end
		else
			packet_out_nxt = 0;	// Empty packet
	end
	
	always_ff @(posedge clk, posedge reset)
	begin
		if (reset)
			packet_out <= 0;
		else
			packet_out <= packet_out_nxt;
	end
endmodule

// Local Variables:
// verilog-typedef-regexp:"_t$"
// End:

