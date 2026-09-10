import 'package:colabroom/services/people_presence.dart';
import 'package:flutter_test/flutter_test.dart';

/// Who is here right now.
///
/// The other half of availability. A status somebody set lasts a fortnight
/// and answers "is it worth asking at all"; the dot lasts as long as the app
/// is open and answers "message them now". Taylor asked for a blend of both,
/// "because the emptiness feeling should go away as the app grows... i want
/// millions of users" — so the shape of this has to be right at four people
/// and still right at four million.
void main() {
  test('presence is scoped to one person per channel', () {
    // The scaling decision, and the only part of it a test can hold.
    //
    // Supabase delivers every join and leave on a channel to everybody
    // subscribed to it. One global `presence:people` channel would hand every
    // client the comings and goings of every user in the product — fine at
    // four, ruinous at four thousand, and the sort of thing that works
    // perfectly until the week it matters.
    //
    // A channel per person means the traffic any one client sees is bounded
    // by its own friend list rather than by how many people use the app.
    expect(PeoplePresence.channelFor('abc'), 'presence:user:abc');
    expect(
      PeoplePresence.channelFor('abc'),
      isNot(PeoplePresence.channelFor('def')),
      reason: 'two people must never share a channel, or each would receive '
          'the other\'s watchers',
    );
  });

  test('watching is capped, so a big list is not a big socket count', () {
    // One subscription per watched person is the cost of the design above.
    // A band is under ten; this is set well past any real list and well short
    // of a number that would matter.
    expect(PeoplePresence.maxWatched, greaterThan(20));
    expect(PeoplePresence.maxWatched, lessThan(200));
  });

  test('nobody is online until something says so', () {
    // Never guesses. An empty set means "we have not heard", which is what
    // the row draws as no dot at all rather than as a grey "offline" — the
    // app does not know the difference and must not imply it does.
    expect(PeoplePresence().onlineNow, isEmpty);
  });
}
