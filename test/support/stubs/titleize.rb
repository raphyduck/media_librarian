class String
  unless method_defined?(:titleize)
    def titleize
      split(/[_\s]+/).map { |word| word.capitalize }.join(' ')
    end
  end
end
