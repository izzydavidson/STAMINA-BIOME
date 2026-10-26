// Playwright test to verify pipeline execution and log streaming
const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: false });
  const page = await browser.newPage();

  try {
    console.log('Navigating to Shiny app...');
    await page.goto('http://127.0.0.1:3973', { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);

    console.log('Navigating to Short Read tab...');
    await page.click('text=Short Read');
    await page.waitForTimeout(1000);

    console.log('Configuring pipeline...');

    // Set run name
    await page.fill('input[id*="run_name"]', 'Playwright_Test_Run');

    // Click Browse button for input file
    console.log('Opening file browser...');
    await page.click('button:has-text("Browse")');
    await page.waitForTimeout(1000);

    // In the file browser modal, navigate to test_inputs
    // Note: This might need adjustment based on actual shinyFiles UI
    const testFilePath = process.env.TEST_FASTQ || require('path').resolve(__dirname, '../main/data/test_inputs/ERR10233589_1.fastq');

    // Since we can't easily interact with shinyFiles modal, let's directly set the hidden input
    await page.evaluate((path) => {
      const inputs = document.querySelectorAll('input[id*="input_path"]');
      inputs.forEach(input => {
        if (input.type === 'text' && input.style.display !== 'none') {
          input.value = path;
        }
      });
      // Also set the hidden input
      const hiddenInputs = document.querySelectorAll('input[id*="input_path"]');
      hiddenInputs.forEach(input => {
        if (input.parentElement.style.display === 'none') {
          input.value = path;
          // Trigger input event
          input.dispatchEvent(new Event('input', { bubbles: true }));
          input.dispatchEvent(new Event('change', { bubbles: true }));
        }
      });
    }, testFilePath);

    await page.waitForTimeout(500);

    console.log('Checking validation...');
    const validationText = await page.textContent('.alert');
    console.log('Validation:', validationText);

    if (validationText.includes('valid')) {
      console.log('Configuration is valid. Running pipeline...');
      await page.click('button:has-text("Run Pipeline")');
      await page.waitForTimeout(2000);

      console.log('Navigating to Run Progress...');
      await page.click('text=Run Progress');
      await page.waitForTimeout(2000);

      console.log('Checking run information...');
      const runId = await page.textContent('text=/20\\d{6}_\\d{6}/');
      console.log('Run ID:', runId);

      console.log('Waiting for logs to appear...');
      await page.waitForTimeout(5000);

      // Check if logs contain pipeline output
      const logContent = await page.textContent('.terminal-output, [class*="log"]');
      console.log('Log content length:', logContent.length);
      console.log('First 500 chars:', logContent.substring(0, 500));

      if (logContent.includes('[dispatch]') || logContent.includes('[container]') || logContent.includes('Pipeline')) {
        console.log('✅ SUCCESS: Logs are being displayed!');
      } else {
        console.log('❌ FAIL: No pipeline logs found in UI');
        console.log('Full log content:', logContent);
      }

      // Wait a bit to see logs streaming
      console.log('Monitoring logs for 10 seconds...');
      for (let i = 0; i < 10; i++) {
        await page.waitForTimeout(1000);
        const currentLogs = await page.textContent('.terminal-output, [class*="log"]');
        console.log(`[${i+1}s] Log length: ${currentLogs.length} chars`);
      }

    } else {
      console.log('❌ Configuration validation failed:', validationText);
    }

    console.log('\nTest complete. Keeping browser open for 30 seconds for inspection...');
    await page.waitForTimeout(30000);

  } catch (error) {
    console.error('Error during test:', error);
  } finally {
    await browser.close();
  }
})();
