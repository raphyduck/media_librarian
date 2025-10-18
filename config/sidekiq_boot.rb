require_relative '../librarian'

$librarian ||= Librarian.new
$librarian.load_requirements unless $librarian.loaded?
