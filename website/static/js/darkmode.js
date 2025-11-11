// Dark mode functionality
(function() {
    const toggle = document.getElementById('darkModeToggle');
    const toggleIcon = toggle.querySelector('.toggle-icon');
    const htmlElement = document.documentElement;
    
    // Check for saved theme preference or default to light mode
    const currentTheme = localStorage.getItem('theme') || 'light';
    htmlElement.setAttribute('data-theme', currentTheme);
    updateIcon(currentTheme);
    
    toggle.addEventListener('click', function() {
        let theme = htmlElement.getAttribute('data-theme');
        let newTheme = theme === 'dark' ? 'light' : 'dark';
        
        htmlElement.setAttribute('data-theme', newTheme);
        localStorage.setItem('theme', newTheme);
        updateIcon(newTheme);
    });
    
    function updateIcon(theme) {
        toggleIcon.textContent = theme === 'dark' ? '☀️' : '🌙';
    }
})();
