--
-- DVB IP
--
-- Copyright 2019 by Suoto <andre820@gmail.com>
--
-- This file is part of DVB IP.
--
-- DVB IP is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- DVB IP is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with DVB IP.  If not, see <http://www.gnu.org/licenses/>.

---------------
-- Libraries --
---------------
library	ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library str_format;
use str_format.str_format_pkg.all;

use work.common_pkg.all;
use work.dvb_utils_pkg.all;

------------------------
-- Entity declaration --
------------------------
entity axi_bit_interleaver is
  generic (DATA_WIDTH : positive := 8);
  port (
    -- Usual ports
    clk            : in  std_logic;
    rst            : in  std_logic;

    cfg_modulation : in  modulation_t;
    cfg_frame_type : in  frame_type_t;
    cfg_code_rate  : in  code_rate_t;

    -- AXI input
    s_tvalid       : in  std_logic;
    s_tdata        : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
    s_tlast        : in  std_logic;
    s_tready       : out std_logic;

    -- AXI output
    m_tready       : in  std_logic;
    m_tvalid       : out std_logic;
    m_tlast        : out std_logic;
    m_tdata        : out std_logic_vector(DATA_WIDTH - 1 downto 0));
end axi_bit_interleaver;

architecture axi_bit_interleaver of axi_bit_interleaver is

  ---------------
  -- Constants --
  ---------------
  constant MAX_ROWS    : integer := 21_600 / DATA_WIDTH;
  constant MAX_COLUMNS : integer := 5;

  type cnt_cfg_t is record
    row_max       : integer;
    row_remainder : integer;
    column_max    : integer;
  end record;

  impure function get_cnt_cfg (
    constant modulation : in modulation_t;
    constant frame_type : in frame_type_t) return cnt_cfg_t is
    variable cfg        : cnt_cfg_t;
  begin

    if frame_type = fecframe_normal then
      if modulation = mod_8psk then
        cfg.row_max := 21_600;
      elsif modulation = mod_16apsk then
        cfg.row_max := 16_200;
      elsif modulation = mod_32apsk then
        cfg.row_max := 12_960;
      end if;
    elsif frame_type = fecframe_short then
      if modulation = mod_8psk then
        cfg.row_max := 5_400;
      elsif modulation = mod_16apsk then
        cfg.row_max := 4_050;
      elsif modulation = mod_32apsk then
        cfg.row_max := 3_240;
      end if;
    end if;

    if modulation = mod_8psk then
      cfg.column_max := 3;
    elsif modulation = mod_16apsk then
      cfg.column_max := 4;
    elsif modulation = mod_32apsk then
      cfg.column_max := 5;
    end if;

    cfg.row_remainder := cfg.row_max rem DATA_WIDTH;
    cfg.row_max := (cfg.row_max + DATA_WIDTH - 1) / DATA_WIDTH;

    return cfg;

  end function get_cnt_cfg;

  -- Read data is an array
  type data_array_t is array (natural range <>)
    of std_logic_vector(DATA_WIDTH - 1 downto 0);

  type column_array_t is array (natural range <>)
    of std_logic_vector(MAX_COLUMNS - 1 downto 0);

  -- We'll need to control RAMs somewhat independently, so pack the write port stuff on
  -- a record
  type ram_write_if_t is record
    addr : unsigned(numbits(MAX_ROWS) downto 0);
    data : std_logic_vector(DATA_WIDTH - 1 downto 0);
    en   : std_logic;
  end record;

  type ram_write_if_array_t is array (natural range <>) of ram_write_if_t;

  -------------
  -- Signals --
  -------------
  -- Write side config
  signal wr_cfg_modulation   : modulation_t;
  signal wr_cfg_frame_type   : frame_type_t;
  signal wr_cfg_code_rate    : code_rate_t;

  signal s_axi_dv            : std_logic;
  signal s_tready_i          : std_logic;
  signal s_tdata_prev        : std_logic_vector(DATA_WIDTH - 1 downto 0);

  signal wr_row_cnt_max      : unsigned(numbits(MAX_ROWS) - 1 downto 0);
  signal wr_column_cnt_max   : unsigned(numbits(MAX_COLUMNS) - 1 downto 0);
  signal wr_remainder_cfg    : unsigned(numbits(DATA_WIDTH) - 1 downto 0);

  signal wr_row_cnt          : unsigned(numbits(MAX_ROWS) - 1 downto 0);
  -- Using integer to make it easier to use as an index. Because the range has limits set,
  -- it should be synthesizable just like an unsigned whose width is numbits(MAX_ROWS) - 1
  signal wr_column_cnt       : natural range 0 to MAX_ROWS - 1;
  signal wr_column_cnt_prev  : natural range 0 to MAX_ROWS - 1;
  signal wr_remainder_cnt    : unsigned(numbits(MAX_ROWS) - 1 downto 0);
  signal wr_ram_ptr          : unsigned(1 downto 0);

  signal ram_wr              : ram_write_if_array_t(0 to MAX_COLUMNS);

  signal dbg_ram_wrdata      : data_array_t(0 to 3);

  signal rd_row_cnt_max      : unsigned(numbits(MAX_ROWS) - 1 downto 0);
  signal rd_remainder_max    : unsigned(numbits(DATA_WIDTH) - 1 downto 0);
  signal rd_column_cnt_max   : unsigned(numbits(MAX_COLUMNS) - 1 downto 0);
  signal rd_ram_ptr          : unsigned(1 downto 0);

  signal rd_row_cnt          : unsigned(numbits(MAX_ROWS) - 1 downto 0);
  signal rd_column_cnt       : unsigned(numbits(MAX_COLUMNS) - 1 downto 0);
  signal rd_column_cnt_prev  : unsigned(numbits(MAX_COLUMNS) - 1 downto 0);

  signal ram_rdaddr          : std_logic_vector(numbits(MAX_ROWS) downto 0);
  signal ram_rddata          : data_array_t(0 to MAX_COLUMNS - 1);

  -- Read side config
  signal rd_cfg_modulation   : modulation_t;
  signal rd_cfg_frame_type   : frame_type_t;
  signal rd_cfg_code_rate    : code_rate_t;

  signal rd_data_sr          : std_logic_vector(MAX_COLUMNS*DATA_WIDTH - 1 downto 0);

  signal interleaved_3c      : std_logic_vector(3*DATA_WIDTH - 1 downto 0);
  signal interleaved_4c      : std_logic_vector(4*DATA_WIDTH - 1 downto 0);
  signal interleaved_5c      : std_logic_vector(5*DATA_WIDTH - 1 downto 0);

  signal m_wr_en             : std_logic := '0';
  signal m_wr_en_prev        : std_logic := '0';
  signal m_wr_full           : std_logic;
  signal m_wr_data           : std_logic_vector(DATA_WIDTH - 1 downto 0);
  signal m_wr_last           : std_logic := '0';
  signal m_wr_last_prev      : std_logic := '0';

  signal tready_bubble       : std_logic;
  signal first_word          : std_logic;

begin

  -------------------
  -- Port mappings --
  -------------------
  -- Generate 1 RAM for each column, each one gets written sequentially
  generate_rams : for column in 0 to MAX_COLUMNS - 1 generate
    ram : entity work.ram_inference
      generic map (
        ADDR_WIDTH          => numbits(MAX_ROWS) + 1,
        DATA_WIDTH          => DATA_WIDTH,
        RAM_INFERENCE_STYLE => "auto",
        EXTRA_OUTPUT_DELAY  => 0)
      port map (
        -- Port A
        clk_a     => clk,
        clken_a   => '1',
        wren_a    => ram_wr(column).en,
        addr_a    => std_logic_vector(ram_wr(column).addr),
        wrdata_a  => ram_wr(column).data,
        rddata_a  => open,

        -- Port B
        clk_b     => clk,
        clken_b   => '1',
        addr_b    => ram_rdaddr,
        rddata_b  => ram_rddata(column));
  end generate generate_rams;

  -- Interleaved data takes 1 cycle after the address has changed, add support for
  -- a couple of cycles to stop the pipeline
  axi_master_adapter_u : entity work.axi_stream_master_adapter
    generic map (
      MAX_SKEW_CYCLES => 2,
      TDATA_WIDTH     => DATA_WIDTH)
    port map (
      -- Usual ports
      clk      => clk,
      reset    => rst,
      -- wanna-be AXI interface
      wr_en    => m_wr_en_prev,
      wr_full  => m_wr_full,
      wr_data  => m_wr_data,
      wr_last  => m_wr_last_prev,
      -- AXI master
      m_tvalid => m_tvalid,
      m_tready => m_tready,
      m_tdata  => m_tdata,
      m_tlast  => m_tlast);

  ------------------------------
  -- Asynchronous assignments --
  ------------------------------
  m_wr_data <= rd_data_sr(DATA_WIDTH - 1 downto 0);

  -- Assign the interleaved data statically
  iter_rows : for row in 0 to DATA_WIDTH - 1 generate
    iter_3_columns : for column in 0 to 2 generate
      interleaved_3c(3*DATA_WIDTH - (3 * row + column) - 1) <= ram_rddata(column)(DATA_WIDTH - row - 1);
    end generate;

    iter_4_columns : for column in 0 to 3 generate
      interleaved_4c(4*DATA_WIDTH - (4 * row + column) - 1) <= ram_rddata(column)(DATA_WIDTH - row - 1);
    end generate iter_4_columns;

    iter_5_columns : for column in 0 to 4 generate
      interleaved_5c(5*DATA_WIDTH - (5 * row + column) - 1) <= ram_rddata(column)(DATA_WIDTH - row - 1);
    end generate iter_5_columns;
  end generate iter_rows;


  s_axi_dv <= '1' when s_tready_i = '1' and s_tvalid = '1' else '0';

  s_tready_i <= '0' when tready_bubble = '1' else
                m_tready when wr_ram_ptr - rd_ram_ptr < 2 else '0';

  -- Assign internals
  s_tready <= s_tready_i;

  ram_rdaddr <= rd_ram_ptr(0) & std_logic_vector(rd_row_cnt);

  dbg_ram_wrdata <= (
                    0 => s_tdata,
                    1 => s_tdata_prev(DATA_WIDTH - 3 downto 0) & s_tdata(DATA_WIDTH - 1 downto DATA_WIDTH - 2),
                    2 => s_tdata_prev(DATA_WIDTH - 5 downto 0) & s_tdata(DATA_WIDTH - 1 downto DATA_WIDTH - 4),
                    3 => s_tdata_prev(DATA_WIDTH - 7 downto 0) & s_tdata(DATA_WIDTH - 1 downto DATA_WIDTH - 6));

  --------------------------------
  -- Handle write side pointers --
  --------------------------------
  write_side_p : process(clk, rst)
    variable cnt_cfg : cnt_cfg_t;
    variable wr_data : std_logic_vector(DATA_WIDTH - 1 downto 0);
  begin
    if rst = '1' then
      wr_column_cnt     <= 0;
      wr_row_cnt        <= (others => '0');
      wr_remainder_cnt  <= (others => '0');
      wr_ram_ptr        <= (others => '0');


      first_word        <= '1';
      wr_row_cnt_max    <= (others => '1');
      wr_remainder_cfg  <= (others => '1');
      wr_column_cnt_max <= (others => '1');

    elsif clk'event and clk = '1' then

      -- 
      if wr_remainder_cnt = 0 then
        wr_data := s_tdata;
      else
        wr_data := s_tdata_prev(DATA_WIDTH - to_integer(wr_remainder_cnt) - 1 downto 0)
                   & s_tdata(DATA_WIDTH - 1 downto DATA_WIDTH - to_integer(wr_remainder_cnt));
      end if;

      -- XXX: explain!!
      ram_wr(wr_column_cnt_prev).data <= s_tdata_prev(DATA_WIDTH - 3 downto 0)
                                         & s_tdata(DATA_WIDTH - 1 downto DATA_WIDTH - 2);

      for column in ram_wr'range loop
        ram_wr(column).en   <= '0';
        ram_wr(column).addr <= wr_ram_ptr(0) & wr_row_cnt;
        ram_wr(column).data <= wr_data;
      end loop;

      tready_bubble <= '0';

      if s_axi_dv = '1' or tready_bubble = '1' then
        s_tdata_prev       <= s_tdata;
        wr_column_cnt_prev <= wr_column_cnt;
        first_word         <= s_tlast;

        ram_wr(wr_column_cnt).en <= '1';

        -- Whenever the number of columns is not a integer multiple of the data width
        -- (e.g. wr_remainder_cfg is not zero), the first row of each column except the
        -- first will generate an extra write to store the remainder itself
        if wr_remainder_cfg /= 0 and wr_column_cnt_prev /= 0 and wr_row_cnt = 0 then
          ram_wr(wr_column_cnt_prev).addr <= ram_wr(wr_column_cnt_prev).addr + 1;
          ram_wr(wr_column_cnt_prev).en   <= '1';
          ram_wr(wr_column_cnt_prev).data <= (others => 'U');
          -- ram_wr(wr_column_cnt_prev).data(to_integer(wr_remainder_cfg) - 1 downto 0)
          --   <= wr_data(DATA_WIDTH - 1 downto DATA_WIDTH - to_integer(wr_remainder_cfg));
        end if;

        if wr_row_cnt /= wr_row_cnt_max then
          wr_row_cnt  <= wr_row_cnt + 1;
        else
          -- Chain counters
          wr_row_cnt       <= (others => '0');
          if wr_column_cnt /= wr_column_cnt_max then
            wr_column_cnt <= wr_column_cnt + 1;
          else
            wr_column_cnt <= 0;
            wr_ram_ptr    <= wr_ram_ptr + 1;
          end if;

          -- Whenever the number of columns is not a integer multiple of the data width
          -- (e.g. wr_remainder_cfg is not zero), the end of the first column will need to
          -- be tweaked to use the correct bits, but the write will take place in the same
          -- processing pipeline.
          if wr_remainder_cfg /= 0 then
            if wr_column_cnt = 0 then
              ram_wr(wr_column_cnt_prev).addr <= ram_wr(wr_column_cnt_prev).addr + 1;
              ram_wr(wr_column_cnt_prev).en   <= '1';
              ram_wr(wr_column_cnt_prev).data <= (others => '0');
              ram_wr(wr_column_cnt_prev).data(to_integer(wr_remainder_cfg) - 1 downto 0)
                <= s_tdata_prev(DATA_WIDTH - 1 downto DATA_WIDTH - to_integer(wr_remainder_cfg));
            end if;
          end if;
          -- Each column filled we shift data a bit more
          wr_remainder_cnt <= wr_remainder_cnt + wr_remainder_cfg;

          -- To handle number of columns not being an integer multiple of the data width,
          -- we'll count one extra row only when writing the first column
          if wr_remainder_cfg /= 0 and wr_column_cnt = 0 then
            wr_row_cnt_max <= wr_row_cnt_max - 1;
          end if;
        end if;

      end if;

      -- Sample config
      if s_axi_dv = '1' and first_word = '1' then
        wr_cfg_modulation  <= cfg_modulation;
        wr_cfg_frame_type  <= cfg_frame_type;
        wr_cfg_code_rate   <= cfg_code_rate;

        cnt_cfg           := get_cnt_cfg(cfg_modulation, cfg_frame_type);
        wr_row_cnt_max    <= to_unsigned(cnt_cfg.row_max - 1, numbits(MAX_ROWS));
        wr_remainder_cfg  <= to_unsigned(cnt_cfg.row_remainder, numbits(DATA_WIDTH));
        wr_column_cnt_max <= to_unsigned(cnt_cfg.column_max - 1, numbits(MAX_COLUMNS));
      end if;

    end if;
  end process write_side_p;

  -------------------------------
  -- Handle read side pointers --
  -------------------------------
  read_side_p : process(clk, rst)
    variable cnt_cfg : cnt_cfg_t;
  begin
    if rst = '1' then
      rd_row_cnt        <= (others => '0');
      rd_column_cnt     <= (others => '0');
      rd_ram_ptr        <= (others => '0');

      rd_row_cnt_max    <= (others => '1');
      rd_column_cnt_max <= (others => '1');

    elsif clk'event and clk = '1' then

      if s_axi_dv = '1' and s_tlast = '1' then
        cnt_cfg           := get_cnt_cfg(wr_cfg_modulation, wr_cfg_frame_type);
        rd_row_cnt_max    <= to_unsigned(cnt_cfg.row_max - 1, numbits(MAX_ROWS));
        rd_remainder_max  <= to_unsigned(cnt_cfg.row_remainder, numbits(DATA_WIDTH));
        rd_column_cnt_max <= to_unsigned(cnt_cfg.column_max - 1, numbits(MAX_COLUMNS));

          -- This will be used for the reading side
        rd_cfg_modulation <= wr_cfg_modulation;
        rd_cfg_frame_type <= wr_cfg_frame_type;
        rd_cfg_code_rate  <= wr_cfg_code_rate;
      end if;

      m_wr_en   <= '0';
      m_wr_last <= '0';

      -- Data comes out of the RAMs 1 cycle after the address has changed, need to keep
      -- track of the actual value being handled
      rd_column_cnt_prev <= rd_column_cnt;
      m_wr_en_prev       <= m_wr_en;
      m_wr_last_prev     <= m_wr_last;

      if m_wr_full = '0' and rd_ram_ptr /= wr_ram_ptr then

        -- If pointers are different and the AXI adapter has space, keep writing
        m_wr_en <= '1';

        -- Read pointers control logic
        if rd_column_cnt /= rd_column_cnt_max then
          rd_column_cnt <= rd_column_cnt + 1;
        else
          rd_column_cnt <= (others => '0');

          if rd_row_cnt /= rd_row_cnt_max then
            rd_row_cnt <= rd_row_cnt + 1;
          else
            rd_row_cnt <= (others => '0');

            rd_ram_ptr <= rd_ram_ptr + 1;
            m_wr_last  <= '1';
          end if;
        end if;
      end if;

      if m_wr_en = '1' then
        if rd_column_cnt_prev = 0 then
          -- Assign to undefined so we can track in simulation the parts that we not
          -- assigned
          rd_data_sr <= (others => 'U');

          -- We'll swap byte ordering (e.g ABCD becomes DCBA) because it's easier to
          -- assign the write data from the shift register's LSB
          if rd_cfg_modulation = mod_8psk then
            if rd_cfg_code_rate = C3_5 then
              rd_data_sr(interleaved_3c'range) <= swap_bytes(interleaved_3c);
            else
              rd_data_sr(interleaved_3c'range) <= swap_bytes(interleaved_3c);
            end if;
          elsif rd_cfg_modulation = mod_16apsk then
            rd_data_sr(interleaved_4c'range) <= swap_bytes(interleaved_4c);
          elsif rd_cfg_modulation = mod_32apsk then
            rd_data_sr <= swap_bytes(interleaved_5c);
          end if;
        else
          -- We'll write the LSB, shift data right
          rd_data_sr <= (DATA_WIDTH - 1 downto 0 => 'U')
            & rd_data_sr(rd_data_sr'length - 1 downto DATA_WIDTH);
        end if;

      end if;

    end if;
  end process read_side_p;

end axi_bit_interleaver;
