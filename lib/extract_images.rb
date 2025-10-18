require 'zlib'

module ExtractImages

  class Extractor

    def initialize
      @processed_pages = []
    end

    def page(page)
      process_page(page, 0)
    end

    private

    def complete_refs
      @complete_refs ||= {}
    end

    def process_page(page, count)
      xobjects = page.xobjects
      return count if xobjects.empty?
      xobjects = Hash[xobjects.sort_by do |name, _|
        cn = name.to_s
        cn.scan(/(?=(([^\d]|^)(\d+)([^\d]|$)))/).each do |n|
          if n[2].length < 3
            cn.gsub!(/([^\d]|^)(#{n[2]})([^\d]|$)/, '\1' + format('%03d', n[2]) + '\3')
          end
        end
        cn
      end]
      xobjects.each do |name, stream|
        next if @processed_pages.include?(name) && xobjects.count > 1
        @processed_pages << name
        case stream.hash[:Subtype]
          when :Image then
            count += 1
            filter = stream.hash[:Filter].is_a?(Array) ? stream.hash[:Filter].first : stream.hash[:Filter]
            case filter
              when :CCITTFaxDecode then
                ExtractImages::Tiff.new(stream).save("#{page.number}-#{count}-#{name}.tif")
              when :DCTDecode, :JPXDecode, :JBIG2Decode then
                ExtractImages::Jpg.new(stream).save("#{page.number}-#{count}-#{name}.jpg")
              else
                ExtractImages::Raw.new(stream).save("#{page.number}-#{count}-#{name}.tif")
                return 0
            end
          when :Form then
            count = process_page(PDF::Reader::FormXObject.new(page, stream), count)
        end
      end
      count
    rescue => e
      MediaLibrarian.app.speaker.tell_error(e, Utils.arguments_dump(binding))
      count
    end

  end

  class Raw
    attr_reader :stream

    def initialize(stream)
      @stream = stream
    end

    def save(filename)
      case @stream.hash[:ColorSpace]
        when :DeviceCMYK then save_cmyk(filename)
        when :DeviceGray then save_gray(filename)
        when :DeviceRGB  then save_rgb(filename)
        else
          MediaLibrarian.app.speaker.speak_up "unsupport color depth #{@stream.hash[:ColorSpace]} #{filename}"
      end
    end

    private

    def save_cmyk(filename)
      h    = stream.hash[:Height]
      w    = stream.hash[:Width]
      bpc  = stream.hash[:BitsPerComponent]
      len  = stream.hash[:Length]
      MediaLibrarian.app.speaker.speak_up "#{filename}: h=#{h}, w=#{w}, bpc=#{bpc}, len=#{len}"

      # Synthesize a TIFF header
      long_tag  = lambda {|tag, count, value| [ tag, 4, count, value ].pack( "ssII" ) }
      short_tag = lambda {|tag, count, value| [ tag, 3, count, value ].pack( "ssII" ) }
      # header = byte order, version magic, offset of directory, directory count,
      # followed by a series of tags containing metadata.
      tag_count = 10
      header = [ 73, 73, 42, 8, tag_count ].pack("ccsIs")
      tiff = header.dup
      tiff << short_tag.call( 256, 1, w ) # image width
      tiff << short_tag.call( 257, 1, h ) # image height
      tiff << long_tag.call( 258, 4, (header.size + (tag_count*12) + 4)) # bits per pixel
      tiff << short_tag.call( 259, 1, 1 ) # compression
      tiff << short_tag.call( 262, 1, 5 ) # colorspace - separation
      tiff << long_tag.call( 273, 1, (10 + (tag_count*12) + 20) ) # data offset
      tiff << short_tag.call( 277, 1, 4 ) # samples per pixel
      tiff << long_tag.call( 279, 1, stream.unfiltered_data.size) # data byte size
      tiff << short_tag.call( 284, 1, 1 ) # planer config
      tiff << long_tag.call( 332, 1, 1)   # inkset - CMYK
      tiff << [0].pack("I") # next IFD pointer
      tiff << [bpc, bpc, bpc, bpc].pack("IIII")
      tiff << stream.unfiltered_data
      File.open(filename, "wb") { |file| file.write tiff }
    end

    def save_gray(filename)
      h    = stream.hash[:Height]
      w    = stream.hash[:Width]
      bpc  = stream.hash[:BitsPerComponent]
      len  = stream.hash[:Length]
      MediaLibrarian.app.speaker.speak_up "#{filename}: h=#{h}, w=#{w}, bpc=#{bpc}, len=#{len}"

      # Synthesize a TIFF header
      long_tag  = lambda {|tag, count, value| [ tag, 4, count, value ].pack( "ssII" ) }
      short_tag = lambda {|tag, count, value| [ tag, 3, count, value ].pack( "ssII" ) }
      # header = byte order, version magic, offset of directory, directory count,
      # followed by a series of tags containing metadata.
      tag_count = 9
      header = [ 73, 73, 42, 8, tag_count ].pack("ccsIs")
      tiff = header.dup
      tiff << short_tag.call( 256, 1, w ) # image width
      tiff << short_tag.call( 257, 1, h ) # image height
      tiff << short_tag.call( 258, 1, 8 ) # bits per pixel
      tiff << short_tag.call( 259, 1, 1 ) # compression
      tiff << short_tag.call( 262, 1, 1 ) # colorspace - grayscale
      tiff << long_tag.call( 273, 1, (10 + (tag_count*12) + 4) ) # data offset
      tiff << short_tag.call( 277, 1, 1 ) # samples per pixel
      tiff << long_tag.call( 279, 1, stream.unfiltered_data.size) # data byte size
      tiff << short_tag.call( 284, 1, 1 ) # planer config
      tiff << [0].pack("I") # next IFD pointer
      p stream.unfiltered_data.size
      tiff << stream.unfiltered_data
      File.open(filename, "wb") { |file| file.write tiff }
    end

    def save_rgb(filename)
      h    = stream.hash[:Height]
      w    = stream.hash[:Width]
      bpc  = stream.hash[:BitsPerComponent]
      len  = stream.hash[:Length]
      MediaLibrarian.app.speaker.speak_up "#{filename}: h=#{h}, w=#{w}, bpc=#{bpc}, len=#{len}"

      # Synthesize a TIFF header
      long_tag  = lambda {|tag, count, value| [ tag, 4, count, value ].pack( "ssII" ) }
      short_tag = lambda {|tag, count, value| [ tag, 3, count, value ].pack( "ssII" ) }
      # header = byte order, version magic, offset of directory, directory count,
      # followed by a series of tags containing metadata.
      tag_count = 8
      header = [ 73, 73, 42, 8, tag_count ].pack("ccsIs")
      tiff = header.dup
      tiff << short_tag.call( 256, 1, w ) # image width
      tiff << short_tag.call( 257, 1, h ) # image height
      tiff << long_tag.call( 258, 3, (header.size + (tag_count*12) + 4)) # bits per pixel
      tiff << short_tag.call( 259, 1, 1 ) # compression
      tiff << short_tag.call( 262, 1, 2 ) # colorspace - RGB
      tiff << long_tag.call( 273, 1, (header.size + (tag_count*12) + 16) ) # data offset
      tiff << short_tag.call( 277, 1, 3 ) # samples per pixel
      tiff << long_tag.call( 279, 1, stream.unfiltered_data.size) # data byte size
      tiff << [0].pack("I") # next IFD pointer
      tiff << [bpc, bpc, bpc].pack("III")
      tiff << stream.unfiltered_data
      File.open(filename, "wb") { |file| file.write tiff }
    end
  end

  class Jpg
    attr_reader :stream

    def initialize(stream)
      @stream = stream
    end

    def save(filename)
      w = stream.hash[:Width]
      h = stream.hash[:Height]
      MediaLibrarian.app.speaker.speak_up "#{filename}: h=#{h}, w=#{w}"
      File.open(filename, "wb") { |file| file.write stream.data }
    end
  end

  class Tiff
    attr_reader :stream

    def initialize(stream)
      @stream = stream
    end

    def save(filename)
      if stream.hash[:DecodeParms][:K] <= 0
        save_group_four(filename)
      else
        MediaLibrarian.app.speaker.speak_up "#{filename}: CCITT non-group 4/2D image."
      end
    end

    private

    # Group 4, 2D
    def save_group_four(filename)
      k    = stream.hash[:DecodeParms][:K]
      h    = stream.hash[:Height]
      w    = stream.hash[:Width]
      bpc  = stream.hash[:BitsPerComponent]
      mask = stream.hash[:ImageMask]
      len  = stream.hash[:Length]
      cols = stream.hash[:DecodeParms][:Columns]
      MediaLibrarian.app.speaker.speak_up "#{filename}: h=#{h}, w=#{w}, bpc=#{bpc}, mask=#{mask}, len=#{len}, cols=#{cols}, k=#{k}"

      # Synthesize a TIFF header
      long_tag  = lambda {|tag, value| [ tag, 4, 1, value ].pack( "ssII" ) }
      short_tag = lambda {|tag, value| [ tag, 3, 1, value ].pack( "ssII" ) }
      # header = byte order, version magic, offset of directory, directory count,
      # followed by a series of tags containing metadata: 259 is a magic number for
      # the compression type; 273 is the offset of the image data.
      tiff = [ 73, 73, 42, 8, 5 ].pack("ccsIs") \
      + short_tag.call( 256, cols ) \
      + short_tag.call( 257, h ) \
      + short_tag.call( 259, 4 ) \
      + long_tag.call( 273, (10 + (5*12) + 4) ) \
      + long_tag.call( 279, len) \
      + [0].pack("I") \
      + stream.data
      File.open(filename, "wb") { |file| file.write tiff }
    end
  end
end