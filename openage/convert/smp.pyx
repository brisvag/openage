# Copyright 2013-2019 the openage authors. See copying.md for legal info.
#
# cython: profile=False

from struct import Struct, unpack_from

from enum import Enum

cimport cython
import numpy
cimport numpy

from libc.stdint cimport uint8_t, uint16_t
from libcpp cimport bool
from libcpp.vector cimport vector

from ..log import spam, dbg


# SMP files have little endian byte order
endianness = "< "


cdef struct boundary_def:
    Py_ssize_t left
    Py_ssize_t right
    bool full_row


# SMP pixels are super special.
cdef enum pixel_type:
    color_standard      # standard pixel
    color_shadow        # shadow pixel
    color_transparent   # transparent pixel
    color_player        # non-outline player color pixel
    color_outline       # player color outline pixel


# One SMP pixel.
cdef struct pixel:
    pixel_type type
    uint8_t index       # index in a palette section
    uint8_t palette     # palette number and palette section
    uint8_t unknown1    # ???
    uint8_t unknown2    # masking for damage?


class SMP:
    """
    Class for reading/converting the SMP image format (successor of SLP).
    This format is used to store all graphics within AoE2: Definitive Edition.
    """

    # struct smp_header {
    #   char file_descriptor[4];
    #   ??? 4 bytes;
    #   int frame_count;
    #   ??? 4 bytes;
    #   ??? 4 bytes;
    #   unsigned int unknown_offset_1;
    #   unsigned int file_size;
    #   ??? 4 bytes;
    #   char comment[32];
    # };
    smp_header = Struct(endianness + "4s i i i i I i I 32s")

    # struct smp_frame_bundle_offset {
    #   unsigned int frame_info_offset;
    # };
    smp_frame_bundle_offset = Struct(endianness + "I")

    # struct smp_frame_bundle_size {
    #   padding 28 bytes;
    #   int frame_bundle_size;
    # };
    smp_frame_bundle_size = Struct(endianness + "28x i")

    # struct smp_frame_info {
    #   int          width;
    #   int          height;
    #   int          hotspot_x;
    #   int          hotspot_y;
    #   int          frame_type;
    #   unsigned int outline_table_offset;
    #   unsigned int qdl_table_offset;
    #   ??? 4 bytes;
    # };
    smp_frame_header = Struct(endianness + "i i i i I I I I")

    def __init__(self, data):
        smp_header = SMP.smp_header.unpack_from(data)
        _, _, frame_count, _, _, _, file_size, _, comment = smp_header

        dbg("SMP")
        dbg(" frame count: %s", frame_count)
        dbg(" file size:   %s B", file_size)
        dbg(" comment:     %s", comment.decode('ascii'))

        # Frame bundles store main graohic, shadow and outline headers
        frame_bundle_offsets = list()

        # read offsets of the smp frames
        for i in range(frame_count):
            frame_bundle_pointer = (SMP.smp_header.size +
                                    i * SMP.smp_frame_bundle_offset.size)

            frame_bundle_offset = SMP.smp_frame_bundle_offset.unpack_from(
                data, frame_bundle_pointer)[0]

            frame_bundle_offsets.append(frame_bundle_offset)

        # SMP graphic frames are created from overlaying
        # the main graphic frame with a shadow frame and
        # and (for units) an outline frame
        self.main_frames = list()
        self.shadow_frames = list()
        self.outline_frames = list()

        spam(FrameHeader.repr_header())

        # read all smp_frame_bundle structs in a frame bundle
        for bundle_offset in frame_bundle_offsets:

            # how many frame headers are in the bundle
            frame_bundle_size = SMP.smp_frame_bundle_size.unpack_from(
                data, bundle_offset)[0]

            for i in range(1, frame_bundle_size + 1):
                frame_header_offset = (bundle_offset +
                                       i * SMP.smp_frame_header.size)

                frame_header = FrameHeader(*SMP.smp_frame_header.unpack_from(
                    data, frame_header_offset), bundle_offset)

                if frame_header.frame_type == 0x02:
                    # frame that store the main graphic
                    self.main_frames.append(SMPMainFrame(frame_header, data))

                elif frame_header.frame_type == 0x04:
                    # frame that stores a shadow
                    self.shadow_frames.append(SMPShadowFrame(frame_header, data))

                elif frame_header.frame_type == 0x08 or \
                     frame_header.frame_type == 0x10:
                    # frame that stores an outline
                    self.outline_frames.append(SMPOutlineFrame(frame_header, data))

                else:
                    raise Exception(
                    "unknown frame header type: " +
                    "%h at offset %h" % (frame_header.frame_type, frame_header_offset))

                spam(frame_header)

    def __str__(self):
        ret = list()

        ret.extend([repr(self), "\n", FrameHeader.repr_header(), "\n"])
        for frame in self.frames:
            ret.extend([repr(frame), "\n"])
        return "".join(ret)

    def __repr__(self):
        # TODO: lookup the image content description
        return "SMP image<%d frames>" % len(self.main_frames)


class FrameHeader:
    def __init__(self, width, height, hotspot_x,
                 hotspot_y, type, outline_table_offset,
                 qdl_table_offset, unknown_value,
                 frame_bundle_offset):

        self.size = (width, height)
        self.hotspot = (hotspot_x, hotspot_y)

        # 2 = normal, 4 = shadow, 8 = outline
        self.frame_type = type

        # table offsets are relative to the frame bundle offset
        self.outline_table_offset = outline_table_offset + frame_bundle_offset
        self.qdl_table_offset = qdl_table_offset + frame_bundle_offset

        # the absolute offset of the bundle
        self.bundle_offset = frame_bundle_offset

    @staticmethod
    def repr_header():
        return ("width x height | hotspot x/y | "
                "frame type | "
                "offset (outline table|qdl table)"
                )

    def __repr__(self):
        ret = (
            "% 5d x% 7d | " % self.size,
            "% 4d /% 5d | " % self.hotspot,
            "% 4d | " % self.frame_type,
            "% 13d| " % self.outline_table_offset,
            "        % 9d|" % self.qdl_table_offset,
        )
        return "".join(ret)

cdef class SMPFrame:
    """
    one image inside the SMP. you can imagine it as a frame of a video.
    """

    # struct smp_frame_row_edge {
    #   unsigned short left_space;
    #   unsigned short right_space;
    # };
    smp_frame_row_edge = Struct(endianness + "H H")

    # struct smp_command_offset {
    #   unsigned int offset;
    # }
    smp_command_offset = Struct(endianness + "I")

    # struct smp_pixel {
    #   unsigned char palette_index;
    #   unsigned char palette;
    #   unsigned char unknown1; occlusion mask?
    #   unsigned char unknown2; occlusion mask?
    # }
    smp_pixel = Struct(endianness + "B B B B")

    # frame information
    cdef object info

    # for each row:
    # contains (left, right, full_row) number of boundary pixels
    cdef vector[boundary_def] boundaries

    # stores the file offset for the first drawing command
    cdef vector[int] cmd_offsets

    # pixel matrix representing the final image
    cdef vector[vector[pixel]] pcolor

    # memory pointer
    cdef const uint8_t *data_raw

    def __init__(self, frame_header, data):
        self.info = frame_header

        if not (isinstance(data, bytes) or isinstance(data, bytearray)):
            raise ValueError("Frame data must be some bytes object")

        # convert the bytes obj to char*
        self.data_raw = data

        cdef size_t i
        cdef int cmd_offset

        cdef size_t row_count = self.info.size[1]

        # process bondary table
        for i in range(row_count):
            outline_entry_position = (self.info.outline_table_offset +
                                      i * SMPFrame.smp_frame_row_edge.size)

            left, right = SMPFrame.smp_frame_row_edge.unpack_from(
                data, outline_entry_position
            )

            # is this row completely transparent?
            if left == 0xFFFF or right == 0xFFFF:
                self.boundaries.push_back(boundary_def(0, 0, True))
            else:
                self.boundaries.push_back(boundary_def(left, right, False))

        # process cmd table
        for i in range(row_count):
            cmd_table_position = (self.info.qdl_table_offset +
                                  i * SMPFrame.smp_command_offset.size)

            cmd_offset = SMPFrame.smp_command_offset.unpack_from(
                data, cmd_table_position)[0] + self.info.bundle_offset
            self.cmd_offsets.push_back(cmd_offset)

        for i in range(row_count):
            self.pcolor.push_back(self.create_color_row(i))

    cdef vector[pixel] create_color_row(self, Py_ssize_t rowid) except +:
        """
        extract colors (pixels) for the given rowid.
        """

        cdef vector[pixel] row_data
        cdef Py_ssize_t i

        first_cmd_offset = self.cmd_offsets[rowid]
        cdef boundary_def bounds = self.boundaries[rowid]
        cdef size_t pixel_count = self.info.size[0]

        # preallocate memory
        row_data.reserve(pixel_count)

        # row is completely transparent
        if bounds.full_row:
            for _ in range(pixel_count):
                row_data.push_back(pixel(color_transparent, 0, 0, 0, 0))

            return row_data

        # start drawing the left transparent space
        for i in range(bounds.left):
            row_data.push_back(pixel(color_transparent, 0, 0, 0, 0))

        # process the drawing commands for this row.
        self.process_drawing_cmds(row_data, rowid,
                                  first_cmd_offset,
                                  pixel_count - bounds.right)

        # finish by filling up the right transparent space
        for i in range(bounds.right):
            row_data.push_back(pixel(color_transparent, 0, 0, 0, 0))

        # verify size of generated row
        if row_data.size() != pixel_count:
            got = row_data.size()
            summary = "%d/%d -> row %d, frame type %d, offset %d / %#x" % (
                got, pixel_count, rowid, self.info.frame_type,
                first_cmd_offset, first_cmd_offset
                )
            txt = "got %%s pixels than expected: %s, missing: %d" % (
                summary, abs(pixel_count - got))

            raise Exception(txt % ("LESS" if got < pixel_count else "MORE"))

        return row_data

    cdef process_drawing_cmds(self, vector[pixel] &row_data,
                              Py_ssize_t rowid,
                              Py_ssize_t first_cmd_offset,
                              size_t expected_size):
        pass

    cdef inline uint8_t get_byte_at(self, Py_ssize_t offset):
        """
        Fetch a byte from the SMP.
        """
        return self.data_raw[offset]

    def get_picture_data(self, main_palette, player_palette):
        """
        Convert the palette index matrix to a colored image.
        """
        return determine_rgba_matrix(self.pcolor, main_palette, player_palette)

    def get_hotspot(self):
        """
        Return the frame's hotspot (the "center" of the image)
        """
        return self.info.hotspot

    def __repr__(self):
        return repr(self.info)


cdef class SMPMainFrame(SMPFrame):
    """
    SMPFrame for the main graphics sprite.
    """

    def __init__(self, frame_header, data):
        super().__init__(frame_header, data)

    cdef process_drawing_cmds(self, vector[pixel] &row_data,
                              Py_ssize_t rowid,
                              Py_ssize_t first_cmd_offset,
                              size_t expected_size):
        """
        extract colors (pixels) for the drawing commands
        found for this row in the SMP frame.
        """

        # position in the data blob, we start at the first command of this row
        cdef Py_ssize_t dpos = first_cmd_offset

        # is the end of the current row reached?
        cdef bool eor = False

        cdef uint8_t cmd
        cdef uint8_t nextbyte
        cdef uint8_t lower_crumb
        cdef int pixel_count

        # work through commands till end of row.
        while not eor:
            if row_data.size() > expected_size:
                raise Exception(
                    "Only %d pixels should be drawn in row %d "
                    "with frame type %d, but we have %d "
                    "already!" % (
                        expected_size, rowid,
                        self.info.frame_type,
                        row_data.size()
                    )
                )

            # fetch drawing instruction
            cmd = self.get_byte_at(dpos)

            # Last 2 bits store command type
            lower_crumb = 0b00000011 & cmd

            # opcode: cmd, rowid: rowid

            if lower_crumb == 0b00000011:
                # eol (end of line) command, this row is finished now.
                eor = True

                continue

            elif lower_crumb == 0b00000000:
                # skip command
                # draw 'count' transparent pixels
                # count = (cmd >> 2) + 1

                pixel_count = (cmd >> 2) + 1

                for _ in range(pixel_count):
                    row_data.push_back(pixel(color_transparent, 0, 0, 0, 0))

            elif lower_crumb == 0b00000001:
                # color_list command
                # draw the following 'count' pixels
                # pixels are stored as rgba 32 bit values
                # count = (cmd >> 2) + 1

                pixel_count = (cmd >> 2) + 1

                for _ in range(pixel_count):

                    pixel_data = list()

                    for _ in range(4):
                        dpos += 1
                        pixel_data.append(self.get_byte_at(dpos))

                    row_data.push_back(pixel(color_standard,
                                             pixel_data[0],
                                             pixel_data[1],
                                             pixel_data[2],
                                             pixel_data[3]))

            elif lower_crumb == 0b00000010:
                # player_color command
                # draw the following 'count' pixels
                # pixels are stored as rgba 32 bit values
                # count = (cmd >> 2) + 1

                pixel_count = (cmd >> 2) + 1

                for _ in range(pixel_count):

                    pixel_data = list()

                    for _ in range(4):
                        dpos += 1
                        pixel_data.append(self.get_byte_at(dpos))

                    row_data.push_back(pixel(color_player,
                                             pixel_data[0],
                                             pixel_data[1],
                                             pixel_data[2],
                                             pixel_data[3]))

            else:
                raise Exception(
                    "unknown smp main frame drawing command: " +
                    "%#x in row %d" % (cmd, rowid))

            # process next command
            dpos += 1

        # end of row reached, return the created pixel array.
        return

    def get_damage_mask(self):
        """
        Convert the 4th pixel byte to a mask used for damaged units.
        """
        return determine_damage_matrix(self.pcolor)


cdef class SMPShadowFrame(SMPFrame):
    """
    SMPFrame for the shadow graphics.
    """

    def __init__(self, frame_header, data):
        super().__init__(frame_header, data)

    cdef process_drawing_cmds(self, vector[pixel] &row_data,
                              Py_ssize_t rowid,
                              Py_ssize_t first_cmd_offset,
                              size_t expected_size):
        """
        extract colors (pixels) for the drawing commands
        found for this row in the SMP frame.
        """

        # position in the data blob, we start at the first command of this row
        cdef Py_ssize_t dpos = first_cmd_offset

        # is the end of the current row reached?
        cdef bool eor = False

        cdef uint8_t cmd
        cdef uint8_t nextbyte
        cdef uint8_t lower_crumb
        cdef int pixel_count

        # work through commands till end of row.
        while not eor:
            if row_data.size() > expected_size:
                raise Exception(
                    "Only %d pixels should be drawn in row %d "
                    "with frame type %d, but we have %d "
                    "already!" % (
                        expected_size, rowid,
                        self.info.frame_type,
                        row_data.size()
                    )
                )

            # fetch drawing instruction
            cmd = self.get_byte_at(dpos)

            # Last 2 bits store command type
            lower_crumb = 0b00000011 & cmd

            # opcode: cmd, rowid: rowid

            if lower_crumb == 0b00000011:
                # eol (end of line) command, this row is finished now.
                eor = True

                # shadows sometimes need an extra pixel at
                # the end
                if row_data.size() < expected_size:
                    # copy the last drawn pixel
                    # (still stored in nextbyte)
                    #
                    # TODO: confirm that this is the
                    #       right way to do it
                    row_data.push_back(pixel(color_shadow,
                                             nextbyte, 0, 0, 0))

                continue

            elif lower_crumb == 0b00000000:
                # skip command
                # draw 'count' transparent pixels
                # count = (cmd >> 2) + 1

                pixel_count = (cmd >> 2) + 1

                for _ in range(pixel_count):
                    row_data.push_back(pixel(color_transparent, 0, 0, 0, 0))

            elif lower_crumb == 0b00000001:
                # color_list command
                # draw the following 'count' pixels
                # pixels are stored as rgba 32 bit values
                # count = (cmd >> 2) + 1

                pixel_count = (cmd >> 2) + 1

                for _ in range(pixel_count):

                    dpos += 1
                    nextbyte = self.get_byte_at(dpos)

                    row_data.push_back(pixel(color_shadow,
                                             nextbyte, 0, 0, 0))

            else:
                raise Exception(
                    "unknown smp shadow frame drawing command: " +
                    "%#x in row %d" % (cmd, rowid))

            # process next command
            dpos += 1

        # end of row reached, return the created pixel array.
        return


cdef class SMPOutlineFrame(SMPFrame):
    """
    SMPFrame for the outline graphics.
    """

    def __init__(self, frame_header, data):
        super().__init__(frame_header, data)

    cdef process_drawing_cmds(self, vector[pixel] &row_data,
                              Py_ssize_t rowid,
                              Py_ssize_t first_cmd_offset,
                              size_t expected_size):
        """
        extract colors (pixels) for the drawing commands
        found for this row in the SMP frame.
        """

        # position in the data blob, we start at the first command of this row
        cdef Py_ssize_t dpos = first_cmd_offset

        # is the end of the current row reached?
        cdef bool eor = False

        cdef uint8_t cmd
        cdef uint8_t nextbyte
        cdef uint8_t lower_crumb
        cdef int pixel_count

        # work through commands till end of row.
        while not eor:
            if row_data.size() > expected_size:
                raise Exception(
                    "Only %d pixels should be drawn in row %d "
                    "with frame type %d, but we have %d "
                    "already!" % (
                        expected_size, rowid,
                        self.info.frame_type,
                        row_data.size()
                    )
                )

            # fetch drawing instruction
            cmd = self.get_byte_at(dpos)

            # Last 2 bits store command type
            lower_crumb = 0b00000011 & cmd

            # opcode: cmd, rowid: rowid

            if lower_crumb == 0b00000011:
                # eol (end of line) command, this row is finished now.
                eor = True

                continue

            elif lower_crumb == 0b00000000:
                # skip command
                # draw 'count' transparent pixels
                # count = (cmd >> 2) + 1

                pixel_count = (cmd >> 2) + 1

                for _ in range(pixel_count):
                    row_data.push_back(pixel(color_transparent, 0, 0, 0, 0))

            elif lower_crumb == 0b00000001:
                # color_list command
                # draw the following 'count' pixels
                # as player outline colors.
                # pixels are stored as rgba 32 bit values
                # count = (cmd >> 2) + 1

                pixel_count = (cmd >> 2) + 1

                for _ in range(pixel_count):
                    # we don't know the color the game wants
                    # so we just draw index 0
                    row_data.push_back(pixel(color_outline,
                                             0, 0, 0, 0))

            else:
                raise Exception(
                    "unknown smp outline frame drawing command: " +
                    "%#x in row %d" % (cmd, rowid))

            # process next command
            dpos += 1

        # end of row reached, return the created pixel array.
        return


@cython.boundscheck(False)
@cython.wraparound(False)
cdef numpy.ndarray determine_rgba_matrix(vector[vector[pixel]] &image_matrix,
                                         main_palette, player_palette):
    """
    converts a palette index image matrix to an rgba matrix.
    """

    cdef size_t height = image_matrix.size()
    cdef size_t width = image_matrix[0].size()

    cdef numpy.ndarray[numpy.uint8_t, ndim=3] array_data = \
        numpy.zeros((height, width, 4), dtype=numpy.uint8)

    # micro optimization to avoid call to ColorTable.__getitem__()
    cdef list m_lookup = main_palette.palette
    cdef list p_lookup = player_palette.palette

    cdef uint8_t r
    cdef uint8_t g
    cdef uint8_t b
    cdef uint8_t a

    cdef vector[pixel] current_row
    cdef pixel px
    cdef pixel_type px_type
    cdef int px_index
    cdef int px_palette

    cdef size_t x
    cdef size_t y

    for y in range(height):

        current_row = image_matrix[y]

        for x in range(width):
            px = current_row[x]
            px_type = px.type
            px_index = px.index
            px_palette = px.palette

            if px_type == color_standard:
                # look up the palette secition
                # palettes have 1024 entries
                # divided into 4 sections
                palette_section = px_palette % 4

                # the index has to be adjusted
                # to the palette section
                index = px_index + 256 * palette_section

                # look up the color index in the
                # main graphics table
                r, g, b, alpha = m_lookup[index]

                # TODO: alpha values are unused
                # in 0x0C and 0x0B version of SMPs
                alpha = 255

            elif px_type == color_transparent:
                r, g, b, alpha = 0, 0, 0, 0

            elif px_type == color_shadow:
                r, g, b, alpha = 0, 0, 0, px_index

            else:
                if px_type == color_player:
                    alpha = 255

                elif px_type == color_outline:
                    alpha = 254

                else:
                    raise ValueError("unknown pixel type: %d" % px_type)

                # get rgb base color from the color table
                # store it the preview player color
                # in the table: [16*player, 16*player+7]
                r, g, b = p_lookup[px_index]

            # array_data[y, x] = (r, g, b, alpha)
            array_data[y, x, 0] = r
            array_data[y, x, 1] = g
            array_data[y, x, 2] = b
            array_data[y, x, 3] = alpha

    return array_data

cdef (uint8_t,uint8_t) get_palette_info(pixel image_pixel):
    """
    returns a 2-tuple that contains the palette number of the pixel as
    the first value and the palette section of the pixel as the
    second value.
    """
    return image_pixel.palette >> 2, image_pixel.palette & 0x03

@cython.boundscheck(False)
@cython.wraparound(False)
cdef numpy.ndarray determine_damage_matrix(vector[vector[pixel]] &image_matrix):
    """
    converts a palette index image matrix to an alpha matrix.

    TODO: figure out how this works exactly
    """

    cdef size_t height = image_matrix.size()
    cdef size_t width = image_matrix[0].size()

    cdef numpy.ndarray[numpy.uint8_t, ndim=3] array_data = \
        numpy.zeros((height, width, 4), dtype=numpy.uint8)


    cdef uint8_t r
    cdef uint8_t g
    cdef uint8_t b
    cdef uint8_t a

    cdef vector[pixel] current_row
    cdef pixel px

    cdef size_t x
    cdef size_t y

    for y in range(height):

        current_row = image_matrix[y]

        for x in range(width):
            px = current_row[x]
            px_u1 = px.unknown1
            px_u2 = px.unknown2

            # TODO: Correct the darkness here
            px_mask = ((px_u2 << 2) | px_u1)

            r, g, b, alpha = 0, 0, 0, px_mask

            # array_data[y, x] = (r, g, b, alpha)
            array_data[y, x, 0] = r
            array_data[y, x, 1] = g
            array_data[y, x, 2] = b
            array_data[y, x, 3] = alpha

    return array_data
