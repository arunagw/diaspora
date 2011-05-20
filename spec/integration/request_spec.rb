#   Copyright (c) 2010, Diaspora Inc.  This file is
#   licensed under the Affero General Public License version 3 or later.  See
#   the COPYRIGHT file.

require 'spec_helper'

describe 'receives a reqiest' do
  it 'successfully receives' do
    req = alice.contacts.create(:person => eve.person).generate_request

    xml = req.to_diaspora_xml

    salmon_xml = Salmon::SalmonSlap.create(alice, xml).xml_for(eve.person)
    proc{
      Job::ReceiveSalmon.perform(eve.id, salmon_xml)
    }.should change{
      eve.contacts.count
    }.by(1)
  end
end
