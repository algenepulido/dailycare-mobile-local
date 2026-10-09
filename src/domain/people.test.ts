import { addressFor, nameList, sharedNames, theOnlyMatch } from './people';

const maria = { id: 'm1', displayName: 'Maria Santos', email: 'nurse@cedar.test' };
const otherMaria = { id: 'm2', displayName: 'Maria Santos', email: 'maria.santos@cedar.test' };
const tomas = { id: 'm3', displayName: 'Tomas Vega', email: 'tomas@cedar.test' };

describe('telling two people with one name apart', () => {
  it('finds the name two people share and leaves the rest alone', () => {
    const shared = sharedNames([maria, otherMaria, tomas]);
    expect(shared.has('Maria Santos')).toBe(true);
    expect(shared.has('Tomas Vega')).toBe(false);
  });

  it('counts people, not rows', () => {
    // Two open assignments for one member, or a member read alongside themselves. One
    // person does not make their own name ambiguous.
    expect(sharedNames([maria, maria, tomas]).size).toBe(0);
  });

  it('ignores a blank name rather than treating blanks as a shared one', () => {
    const shared = sharedNames([
      { id: 'a', displayName: '  ' },
      { id: 'b', displayName: '' },
    ]);
    expect(shared.size).toBe(0);
  });

  it('shows an address only for a name that needs one', () => {
    const shared = sharedNames([maria, otherMaria, tomas]);
    expect(addressFor(maria.displayName, maria.email, shared)).toBe('nurse@cedar.test');
    expect(addressFor(tomas.displayName, tomas.email, shared)).toBeNull();
  });

  it('renders nothing rather than an empty line when the address is missing', () => {
    // An invitation can carry a name the server has no address against. A blank line still
    // takes the gap above it, so the caller needs to be told to skip it entirely.
    const shared = sharedNames([maria, otherMaria]);
    expect(addressFor('Maria Santos', undefined, shared)).toBeNull();
    expect(addressFor('Maria Santos', '   ', shared)).toBeNull();
  });

  it('qualifies only the ambiguous names in a line of several', () => {
    const shared = sharedNames([maria, otherMaria, tomas]);
    expect(nameList([maria, otherMaria, tomas], shared)).toBe(
      'Maria Santos (nurse@cedar.test), Maria Santos (maria.santos@cedar.test), Tomas Vega',
    );
  });

  it('is the same answer on every list, not just the one being looked at', () => {
    // The point of working the set out building-wide. Teresa has one Maria assigned and the
    // other is only offered; a list-wide rule would print both bare and the manager would be
    // choosing between two identical rows.
    const shared = sharedNames([maria, otherMaria, tomas]);
    expect(nameList([maria], shared)).toBe('Maria Santos (nurse@cedar.test)');
  });
});

describe('the one resident a name can mean', () => {
  const alma = { id: 'r1', displayName: 'Alma Vidal' };
  const maria = { id: 'r2', displayName: 'Maria Santos' };
  const otherMaria = { id: 'r3', displayName: 'Maria Santos' };

  it('finds the one person a name names', () => {
    expect(theOnlyMatch([alma, maria], 'Alma Vidal')).toBe(alma);
  });

  it('is not case or whitespace sensitive, because the name was typed', () => {
    expect(theOnlyMatch([alma, maria], '  alma vidal ')).toBe(alma);
  });

  it('refuses to pick when two people answer to the name', () => {
    // The whole point. Taking the first here filed a day against the wrong resident and
    // showed it to the wrong family.
    expect(theOnlyMatch([maria, otherMaria], 'Maria Santos')).toBeNull();
  });

  it('refuses when nobody answers to it, the same way', () => {
    expect(theOnlyMatch([alma], 'Marisol Reyes')).toBeNull();
    expect(theOnlyMatch([alma], '   ')).toBeNull();
  });
});
