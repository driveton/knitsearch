# frozen_string_literal: true

require "cgi"

module Knitsearch
  # HTML highlighter for search results. Replaces placeholder marks inserted by
  # FTS5's highlight() function with <mark> tags. The marks are control characters
  # chosen to be unlikely in user content.
  module Highlighter
    extend self

    def render(text)
      return nil if text.nil?

      # Escape user content FIRST, then convert sentinels to <mark>. Reordering
      # this would render user-stored HTML verbatim and produce stored XSS.
      CGI.escapeHTML(text.to_s)
         .gsub(CGI.escapeHTML(opening_mark), "<mark>")
         .gsub(CGI.escapeHTML(closing_mark), "</mark>")
         .html_safe
    end

    def opening_mark
      OPENING_MARK
    end

    def closing_mark
      CLOSING_MARK
    end

    private

    OPENING_MARK = "\x02knitsearch_open\x03"
    CLOSING_MARK = "\x02knitsearch_close\x03"
  end
end
