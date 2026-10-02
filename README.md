# Glow for Facebook
A simple, clean, and powerful tweak for Facebook

## Screenshots
<table>
   <tr>
      <td><img src="Sileo/screenshot1.jpg" alt="Screenshot 1" /></td>
      <td><img src="Sileo/screenshot2.jpg" alt="Screenshot 2" /></td>
      <td><img src="Sileo/screenshot3.jpg" alt="Screenshot 3" /></td>
   </tr>
</table>

<details>
  <summary>More screenshots</summary>
  <table>
    <tr>
      <td><img src="Sileo/screenshot4.jpg" alt="Screenshot 4" /></td>
      <td><img src="Sileo/screenshot5.jpg" alt="Screenshot 5" /></td>
      <td><img src="Sileo/screenshot6.jpg" alt="Screenshot 6" /></td>
    </tr>
  </table>
</details>

## Main Features
<li>Download Media: Download whatever you like — videos, images, Reels, and even stories</li>
<li>Anonymity: Stay unseen. View stories and mark them as seen only when you want to</li>
<li>Confirmation: Worried about accidental likes? Now you can relax</li>
<li>Simplicity: Flexible, intuitive settings — all tailored to you</li>
<li>And More: Glow isn’t just a list of features. It unlocks even more tools for comfort and privacy</li>
<br>


**Glow settings are available via long press on any tab**

## Facebook 580 navbar compatibility

Generated Facebook IPAs contain the original Glow 1.3.1 `Glow.dylib` and the separate `GlowCompat.dylib`. GlowCompat restores the Glow settings context-menu entry on Facebook 580's floating navbar; it does not replace or merge into Glow. Other navbar features may need future compatibility work.

GlowCompat is packaged in `Facebook.app/Frameworks` but is not a Facebook launch dependency. In the tested LiveContainer/Facebook 580 setup, loading any second injected dylib at launch caused Glow's initializer to abort. The exact cause is unknown. A small initializer embedded in the Facebook executable waits 500 ms, finds that Facebook image with `dladdr`, and loads GlowCompat later. It uses `S_INIT_FUNC_OFFSETS`; it does not use `LC_ROUTINES_64` or a helper dylib.

Use a clean decrypted IPA as workflow input. Do not manually add GlowCompat to a generated IPA: it is already bundled and loaded by the late loader.


## Reviews
Review by [@qbap](https://github.com/qbap) on ONE Jailbreak: https://onejailbreak.com/blog/glow-facebook-ipa/

## How to build a Glow for Facebook app using Github actions
> [!NOTE]
> If this your first time, complete following steps before starting:
>
> 1. Fork this repository using the fork button on the top right
> 2. On your forked repository, go to **Actions** tab and click **I understand my workflows, go ahead and enable them**.

<ol>
  <li>Click on <strong>Sync fork</strong>, and if your branch is out-of-date, click on <strong>Update branch</strong>.</li>
  <li>Navigate to the <strong>Actions tab</strong> in your forked repository and select <strong>Build Glow for Facebook app</strong>.</li>
  <li>Click the <strong>Run workflow</strong> button located on the right side.</li>
  <li>Prepare a decrypted .ipa file <em>(we cannot provide this due to legal reasons)</em>, then upload it to a file provider (e.g., filebin.net, filemail.com, or Dropbox is recommended). Paste the URL of the decrypted IPA file in the provided field.</li>
  <li><strong>NOTE:</strong> Make sure to provide a direct download link to the file, not a link to a webpage. Otherwise, the process will fail.</li>
  <li>You can also change the BundleID and Display Name if desired.</li>
  <li>Make sure all inputs are correct, then click <strong>Run workflow</strong> to start the process.</li>
  <li>Wait for the build to finish. You can download <strong>Glow for Facebook</strong> app from the releases section of your forked repo. (If you can't find the releases section, go to your forked repo and add /releases to the URL, i.e., github.com/user/Glow/releases.)</li>
</ol>
