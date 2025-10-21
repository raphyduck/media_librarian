module MediaLibrarian
  module Version
    STRING = "0.1".freeze

    def self.to_s
      STRING
    end
  end

  VERSION = Version::STRING
end
