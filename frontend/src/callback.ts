import { userManager } from './auth';

userManager.signinRedirectCallback().then(() => {
  window.location.replace('/');
}).catch((err) => {
  console.error('OIDC callback error:', err);
  window.location.replace('/');
});
