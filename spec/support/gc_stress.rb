# frozen_string_literal: true

# Opt-in GC torture for the C extension: PATRON_GC_STRESS=1 bundle exec rspec
if ENV['PATRON_GC_STRESS']
  begin
    GC.auto_compact = true if GC.respond_to?(:auto_compact=)
  rescue NotImplementedError
    # Platforms without compaction support just run the plain stress
  end

  # Compaction after every example that touched the extension is what finds unregistered
  # or unpinned VALUEs. GC.stress on the pure-Ruby unit specs is deliberately not done:
  # it takes ten minutes and trips Marshal corruption inside Ruby itself (3.4.12), not in Patron
  RSpec.configure do |c|
    c.around(:each, :session) do |example|
      example.run
      GC.verify_compaction_references(expand_heap: true, toward: :empty)
    end
  end
end
