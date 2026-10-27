# frozen_string_literal: true

# Opt-in GC torture for the C extension: PATRON_GC_STRESS=1 bundle exec rspec
if ENV['PATRON_GC_STRESS']
  begin
    GC.auto_compact = true if GC.respond_to?(:auto_compact=)
  rescue NotImplementedError
    # Platforms without compaction support just run the plain stress
  end

  RSpec.configure do |c|
    c.around(:each, :session) do |example|
      example.run
      GC.verify_compaction_references(expand_heap: true, toward: :empty)
    end

    c.around(:each, :unit) do |example|
      GC.stress = true
      example.run
    ensure
      GC.stress = false
    end
  end
end
