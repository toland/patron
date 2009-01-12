require 'pathname'

cwd = Pathname(__FILE__).dirname
$:.unshift(cwd) unless $:.include?(cwd) || $:.include?(cwd.expand_path)

require 'patron/version'
require 'patron/session'
