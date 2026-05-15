# frozen_string_literal: true

module ArticlesTestHelper
  extend ActiveSupport::Concern

  def setup
    super
    reset_article_searchable_state!
    Article.delete_all
    TrigramArticle.delete_all
    EnglishArticle.delete_all
    ApiTestArticle.delete_all
    Article.searchable_by against: { title: "A", body: "B" }
  end

  def teardown
    super
  end

  private
    def reset_article_searchable_state!
      [Article, TrigramArticle, EnglishArticle, ApiTestArticle].each do |model|
        model.instance_variable_set(:@rich_text_mapping, {})
        model.instance_variable_set(:@associated_mapping, {})
        model.instance_variable_set(:@searchable_columns, nil)
        model.instance_variable_set(:@searchable_options, nil)
        model.instance_variable_set(:@searchable_dictionary, nil)
        model.instance_variable_set(:@knitsearch_callbacks_installed, false)
      end
    end
end
