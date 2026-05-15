# frozen_string_literal: true

namespace :knitsearch do
  desc "Backfill the FTS index from existing records. Usage: bin/rails knitsearch:backfill[Article]"
  task :backfill, [:model_name] => :environment do |_task, args|
    model_name = args[:model_name]
    raise "Model name required: bin/rails knitsearch:backfill[ModelName]" if model_name.blank?

    model_class = model_name.classify.constantize
    raise "#{model_name} does not include Knitsearch::Model" unless model_class.respond_to?(:knitsearch_backfill!)

    puts "Backfilling search index for #{model_class.name}..."
    model_class.knitsearch_backfill!
    puts "Backfill complete. Source table has #{model_class.count} rows."
  rescue NameError
    raise "Could not find model #{model_name}"
  end

  desc "Rebuild the FTS5 index for a model. Usage: bin/rails knitsearch:reindex[Article]"
  task :reindex, [:model_name] => :environment do |_task, args|
    model_name = args[:model_name]
    raise "Model name required: bin/rails knitsearch:reindex[ModelName]" if model_name.blank?

    model_class = model_name.classify.constantize
    raise "#{model_name} does not include Knitsearch::Model" unless model_class.respond_to?(:reindex!)

    puts "Reindexing search for #{model_class.name}..."
    model_class.reindex!
    puts "Reindex complete for #{model_class.name}. Source table has #{model_class.count} rows."
  rescue NameError
    raise "Could not find model #{model_name}"
  end
end
