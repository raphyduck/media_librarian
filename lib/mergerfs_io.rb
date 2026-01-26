module MergerfsIo
  module_function

  def same_filesystem?(src, dst)
    dst_path = File.exist?(dst) ? dst : File.dirname(dst)
    File.stat(src).dev == File.stat(dst_path).dev
  end

  def filesystem_type_for(path)
    path = File.expand_path(path)
    path = File.dirname(path) unless File.exist?(path)
    best = nil
    best_len = -1
    File.foreach('/proc/self/mountinfo') do |line|
      left, right = line.split(' - ', 2)
      next unless right
      fields = left.split(' ')
      mount_point = fields[4]
      next unless mount_point
      matches = mount_point == '/' || path == mount_point || path.start_with?(mount_point + '/')
      next unless matches
      len = mount_point.length
      next unless len > best_len
      best_len = len
      best = right.split(' ', 2)[0]
    end
    best
  end

  def source_is_mergerfs?(src)
    fstype = filesystem_type_for(src)
    fstype == 'fuse.mergerfs' || fstype == 'mergerfs'
  end

  def accelerated_source_path(src, dst, local_branch: ENV['LOCAL_BRANCH'])
    return src if same_filesystem?(src, dst)
    return src unless source_is_mergerfs?(src)

    allpaths = xattr_value(src, 'user.mergerfs.allpaths')
    fullpath = xattr_value(src, 'user.mergerfs.fullpath')

    if allpaths
      paths = allpaths.split("\n").map(&:strip).reject(&:empty?)
      if local_branch && !local_branch.empty?
        preferred = paths.find { |path| path.start_with?(local_branch) && File.exist?(path) }
        return preferred if preferred
      end
      preferred = paths.find { |path| File.exist?(path) }
      return preferred if preferred
    end

    return fullpath if fullpath && !fullpath.empty?
    src
  end

  def xattr_value(path, name)
    return unless File.exist?(path)
    @getxattr ||= begin
      require 'fiddle'
      Fiddle::Function.new(Fiddle.dlopen(nil)['getxattr'],
                           [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T],
                           Fiddle::TYPE_SSIZE_T)
    rescue LoadError, Fiddle::DLError
      nil
    end
    return unless @getxattr
    size = @getxattr.call(path, name, nil, 0)
    return if size <= 0
    buffer = Fiddle::Pointer.malloc(size)
    read = @getxattr.call(path, name, buffer, size)
    return if read <= 0
    buffer.to_s(read)
  rescue StandardError
    nil
  end
end

MergerfsIO = MergerfsIo
