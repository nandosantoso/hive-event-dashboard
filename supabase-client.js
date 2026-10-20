(() => {
  const config = window.HIVE_SUPABASE_CONFIG || {};
  const url = String(config.url || '').replace(/\/$/, '');
  const key = String(config.publishableKey || '');
  const sessionKey = 'hive-event-dashboard:supabase-session';
  let session = null;
  try { session = JSON.parse(localStorage.getItem(sessionKey)); } catch {}

  function setSession(value) {
    session = value || null;
    try { if (session) localStorage.setItem(sessionKey, JSON.stringify(session)); else localStorage.removeItem(sessionKey); } catch {}
  }
  function configured() { return Boolean(url && key); }
  async function request(path, options = {}, useSession = true) {
    if (!configured()) throw new Error('Supabase belum dikonfigurasi.');
    const headers = new Headers(options.headers || {});
    headers.set('apikey', key);
    if (useSession && session?.access_token) headers.set('Authorization', `Bearer ${session.access_token}`);
    else headers.delete('Authorization');
    if (options.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
    const response = await fetch(`${url}${path}`, { ...options, headers });
    const raw = await response.text();
    let data = null;
    try { data = raw ? JSON.parse(raw) : null; } catch { data = raw; }
    if (!response.ok) {
      const message = data?.msg || data?.message || data?.error_description || data?.error || `Supabase request failed (${response.status})`;
      const error = new Error(message); error.status = response.status; error.code = data?.code; throw error;
    }
    return data;
  }
  async function auth(path, body) {
    const data = await request(`/auth/v1/${path}`, { method: 'POST', body: JSON.stringify(body) }, false);
    if (data?.access_token) setSession(data);
    return data;
  }
  async function currentUser() {
    if (!session?.access_token) return null;
    try { return await request('/auth/v1/user'); }
    catch (error) {
      if (!session?.refresh_token) { setSession(null); return null; }
      try {
        const refreshed = await auth('token?grant_type=refresh_token', { refresh_token: session.refresh_token });
        return refreshed.user || await request('/auth/v1/user');
      } catch { setSession(null); return null; }
    }
  }
  async function signUp(email, password, name) {
    // GitHub Pages is hosted under a repository path. Tell Supabase exactly
    // where to return after email confirmation instead of relying on a
    // potentially stale Site URL from the project defaults.
    let redirectTo = '';
    if (window.location.protocol !== 'file:') {
      const pathname = window.location.pathname.endsWith('/')
        ? window.location.pathname
        : `${window.location.pathname}/`;
      redirectTo = `${window.location.origin}${pathname}`;
    }
    const endpoint = redirectTo ? `signup?redirect_to=${encodeURIComponent(redirectTo)}` : 'signup';
    return auth(endpoint, { email, password, data: { full_name: name } });
  }
  async function signIn(email, password) {
    return auth('token?grant_type=password', { email, password });
  }
  async function resetPassword(email) {
    const redirectTo = window.location.protocol === 'file:' ? '' : `${window.location.origin}${window.location.pathname.endsWith('/') ? window.location.pathname : `${window.location.pathname}/`}`;
    const endpoint = redirectTo ? `recover?redirect_to=${encodeURIComponent(redirectTo)}` : 'recover';
    return request(`/auth/v1/${endpoint}`, { method: 'POST', body: JSON.stringify({ email }) }, false);
  }
  async function updatePassword(password) {
    return request('/auth/v1/user', { method: 'PUT', body: JSON.stringify({ password }) });
  }
  async function signOut() {
    try { if (session?.access_token) await request('/auth/v1/logout', { method: 'POST' }); }
    finally { setSession(null); }
  }
  async function profile(userId) {
    const rows = await request(`/rest/v1/hive_profiles?select=id,email,full_name,role,active,created_at&id=eq.${encodeURIComponent(userId)}&limit=1`);
    return rows?.[0] || null;
  }
  async function profiles() {
    return request('/rest/v1/hive_profiles?select=id,email,full_name,role,active,created_at&order=created_at.asc');
  }
  async function updateProfile(id, changes) {
    await request(`/rest/v1/hive_profiles?id=eq.${encodeURIComponent(id)}`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify(changes) });
  }
  async function invite(email, name, role) {
    return request('/rest/v1/rpc/hive_invite_user', { method: 'POST', body: JSON.stringify({ p_email: email, p_name: name, p_role: role }) });
  }
  async function workspace() {
    const rows = await request('/rest/v1/hive_workspace?select=events&id=eq.main&limit=1');
    return rows?.[0]?.events || null;
  }
  async function saveWorkspace(events) {
    return request('/rest/v1/hive_workspace?on_conflict=id', {
      method: 'POST', headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify({ id: 'main', events })
    });
  }
  async function addAudit({ eventId = '', eventName = '', action, detail = '' }) {
    return request('/rest/v1/rpc/hive_record_audit', {
      method: 'POST', body: JSON.stringify({ p_event_id: eventId, p_event_name: eventName, p_action: action, p_detail: detail })
    });
  }
  async function pruneExpired() {
    return request('/rest/v1/rpc/hive_prune_expired_data', { method: 'POST', body: '{}' });
  }
  async function auditLogs(search = '') {
    const filter = search ? `&or=(event_name.ilike.*${encodeURIComponent(search)}*,actor_name.ilike.*${encodeURIComponent(search)}*,actor_email.ilike.*${encodeURIComponent(search)}*,action.ilike.*${encodeURIComponent(search)}*,detail.ilike.*${encodeURIComponent(search)}*)` : '';
    const cutoff = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
    return request(`/rest/v1/hive_audit_log?select=id,event_id,event_name,actor_name,actor_email,action,detail,created_at&created_at=gte.${encodeURIComponent(cutoff)}&order=created_at.desc&limit=500${filter}`);
  }
  window.HiveCloud = { configured, get session(){ return session; }, setSession, currentUser, signUp, signIn, resetPassword, updatePassword, signOut, profile, profiles, updateProfile, invite, workspace, saveWorkspace, addAudit, pruneExpired, auditLogs };
})();
