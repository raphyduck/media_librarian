require 'fileutils'

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

  def destination_is_mergerfs?(dst)
    target = File.exist?(dst) ? dst : File.dirname(dst)
    fstype = filesystem_type_for(target)
    fstype == 'fuse.mergerfs' || fstype == 'mergerfs'
  end

  def resolve_destination_local(dst_mergerfs_path)
    merge_mnt = ENV['MERGE_MNT']
    local_branch = ENV['LOCAL_BRANCH']
    return dst_mergerfs_path if merge_mnt.to_s.empty? || local_branch.to_s.empty?

    rel = dst_mergerfs_path.sub(merge_mnt, '').delete_prefix('/')
    File.join(local_branch, rel)
  end

  def effective_destination_for_write(dst)
    merge_mnt = ENV['MERGE_MNT']
    return dst if merge_mnt.to_s.empty?
    return dst unless dst.start_with?(merge_mnt + '/')
    return dst unless destination_is_mergerfs?(dst)

    local_dst = resolve_destination_local(dst)
    FileUtils.mkdir_p(File.dirname(local_dst))
    local_dst
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
