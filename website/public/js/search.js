// Simple search functionality
var lunrIndex, pagesIndex;

function initLunr() {
    $.getJSON(baseurl + "index.json")
        .done(function(index) {
            pagesIndex = index;
            lunrIndex = lunr(function() {
                this.ref("uri");
                this.field("title", { boost: 15 });
                this.field("tags", { boost: 10 });
                this.field("content", { boost: 5 });
                
                pagesIndex.forEach(function(page) {
                    this.add(page);
                }, this);
            });
            
            // Setup search input handler
            $("#search-by").on("input", function() {
                performSearch($(this).val());
            });
        })
        .fail(function(jqxhr, textStatus, error) {
            console.error("Error loading search index:", error);
        });
}

function performSearch(query) {
    if (query.length < 2) {
        hideSearchResults();
        return;
    }
    
    try {
        var results = lunrIndex.search(query + "~1"); // Fuzzy search
        displayResults(results);
    } catch(e) {
        console.error("Search error:", e);
    }
}

function displayResults(results) {
    var $resultsDiv = $("#search-results");
    
    if (!$resultsDiv.length) {
        $resultsDiv = $('<div id="search-results"></div>');
        $("#search-by").parent().append($resultsDiv);
    }
    
    if (results.length === 0) {
        $resultsDiv.html('<div class="no-results">No results found</div>').show();
        return;
    }
    
    var html = '<ul>';
    results.slice(0, 10).forEach(function(result) {
        var page = pagesIndex.find(function(p) { return p.uri === result.ref; });
        if (page) {
            html += '<li><a href="' + page.uri + '">' + 
                    '<div class="result-title">' + page.title + '</div>' +
                    '<div class="result-snippet">' + truncate(page.content, 100) + '</div>' +
                    '</a></li>';
        }
    });
    html += '</ul>';
    
    $resultsDiv.html(html).show();
}

function hideSearchResults() {
    $("#search-results").hide();
}

function truncate(text, length) {
    if (text.length <= length) return text;
    return text.substr(0, length) + '...';
}

// Close search results when clicking outside
$(document).on('click', function(e) {
    if (!$(e.target).closest('.searchbox').length) {
        hideSearchResults();
    }
});
